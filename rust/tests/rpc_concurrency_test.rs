use i18n_status_core::contract::{CLIENT_NAME, CORE_NAME, CORE_VERSION, PROTOCOL_VERSION};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct CoreProcess {
    child: ChildGuard,
    line_rx: mpsc::Receiver<String>,
}

impl CoreProcess {
    fn spawn() -> Self {
        let mut child = ChildGuard(
            Command::new(env!("CARGO_BIN_EXE_i18n-status-core"))
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .expect("failed to start core binary"),
        );
        let stdout = child.0.stdout.take().expect("stdout should be piped");
        let (line_tx, line_rx) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else {
                    break;
                };
                if line_tx.send(line).is_err() {
                    break;
                }
            }
        });
        Self { child, line_rx }
    }

    fn stdin(&mut self) -> &mut ChildStdin {
        self.child.0.stdin.as_mut().expect("stdin should be piped")
    }

    fn send(&mut self, request: &Value) {
        self.send_batch(std::slice::from_ref(request));
    }

    /// Sends requests in a single write so the core reads them back to back.
    fn send_batch(&mut self, requests: &[Value]) {
        let payload: String = requests
            .iter()
            .map(|request| format!("{request}\n"))
            .collect();
        let stdin = self.stdin();
        stdin
            .write_all(payload.as_bytes())
            .expect("failed to send requests");
        stdin.flush().expect("failed to flush requests");
    }

    fn receive(&self, timeout: Duration) -> Value {
        let line = self
            .line_rx
            .recv_timeout(timeout)
            .expect("core should respond before the test deadline");
        serde_json::from_str(&line).expect("stdout should contain JSON-RPC")
    }

    fn initialize(&mut self, id: u64) {
        self.send(&initialize_request(id));
        let response = self.receive(Duration::from_secs(10));

        assert_eq!(response["id"], id);
        assert!(response.get("error").is_none(), "{response}");
        assert_eq!(response["result"]["core"]["name"], CORE_NAME);
        assert_eq!(response["result"]["core"]["version"], CORE_VERSION);
        assert_eq!(response["result"]["protocol_version"], PROTOCOL_VERSION);
    }
}

fn initialize_request(id: u64) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": {
            "client": {
                "name": CLIENT_NAME,
                "version": CORE_VERSION,
            },
            "protocol_version": PROTOCOL_VERSION,
        }
    })
}

fn scan_request(id: u64) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "scan/extract",
        "params": {
            "source": "t(\"ready\")",
            "lang": "typescript",
            "fallback_namespace": "common",
        }
    })
}

fn unique_temp_dir() -> PathBuf {
    static NEXT_DIR: AtomicUsize = AtomicUsize::new(0);
    let path = std::env::temp_dir().join(format!(
        "i18n-status-core-rpc-concurrency-{}-{}-{}",
        std::process::id(),
        NEXT_DIR.fetch_add(1, Ordering::Relaxed),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after unix epoch")
            .as_nanos()
    ));
    fs::create_dir_all(&path).expect("failed to create temp directory");
    path
}

#[test]
fn doctor_requests_require_the_exact_initialization_handshake() {
    let project_root = unique_temp_dir();
    let doctor_request = |id| {
        json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "doctor/diagnose",
            "params": {
                "project_root": project_root,
                "roots": [],
                "primary_lang": "en",
                "languages": ["en"],
                "fallback_namespace": "common",
                "open_buffers": [],
                "deadline_ms": 1000,
            }
        })
    };
    let mut core = CoreProcess::spawn();

    core.send(&doctor_request(1));
    let rejected = core.receive(Duration::from_secs(2));
    assert_eq!(rejected["id"], 1);
    assert_eq!(rejected["error"]["code"], -32600);
    assert!(rejected.get("result").is_none(), "{rejected}");
    assert!(matches!(
        core.line_rx.recv_timeout(Duration::from_millis(100)),
        Err(mpsc::RecvTimeoutError::Timeout)
    ));

    core.initialize(2);
    core.send(&doctor_request(3));
    loop {
        let message = core.receive(Duration::from_secs(10));
        if message.get("method").and_then(Value::as_str) == Some("doctor/progress") {
            assert_eq!(message["params"]["request_id"], 3);
            continue;
        }
        if message.get("id").and_then(Value::as_u64) == Some(3) {
            assert!(message.get("error").is_none(), "{message}");
            assert_eq!(message["result"]["cancelled"], false);
            break;
        }
    }

    drop(core);
    let _ = fs::remove_dir_all(project_root);
}

/// Creates a locale file backed by a FIFO so that Doctor blocks while indexing resources
/// until the test writes the locale content.
fn blocked_locale_project() -> (PathBuf, PathBuf) {
    let project_root = unique_temp_dir();
    let locale_dir = project_root.join("locales/en");
    fs::create_dir_all(&locale_dir).expect("failed to create locale directory");
    let fifo = locale_dir.join("common.json");
    let status = Command::new("mkfifo")
        .arg(&fifo)
        .status()
        .expect("mkfifo should be available");
    assert!(status.success(), "mkfifo failed: {status}");
    (project_root, fifo)
}

/// Opens the FIFO for writing. The open only completes once Doctor has opened the
/// FIFO for reading, which proves that Doctor is running and blocked on it.
fn wait_for_doctor_reader(fifo: &Path) -> fs::File {
    let (file_tx, file_rx) = mpsc::channel();
    let fifo = fifo.to_path_buf();
    std::thread::spawn(move || {
        let file = fs::OpenOptions::new().write(true).open(fifo);
        let _ = file_tx.send(file);
    });
    file_rx
        .recv_timeout(Duration::from_secs(10))
        .expect("doctor should start reading the blocked locale file")
        .expect("failed to open locale FIFO for writing")
}

fn doctor_request(id: u64, project_root: &Path, open_buffers: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "doctor/diagnose",
        "params": {
            "project_root": project_root,
            "roots": [{
                "kind": "i18next",
                "path": project_root.join("locales")
            }],
            "primary_lang": "en",
            "languages": ["en"],
            "fallback_namespace": "common",
            "open_buffers": open_buffers,
            "deadline_ms": 30_000,
        }
    })
}

fn assert_ready_scan(response: &Value, id: u64) {
    assert_eq!(response["id"], id);
    assert!(response.get("error").is_none(), "{response}");
    let items = response["result"]["items"]
        .as_array()
        .expect("scan result should contain items");
    assert_eq!(items.len(), 1, "{response}");
    assert_eq!(items[0]["key"], "common:ready");
}

/// Receives the next response, skipping Doctor progress notifications.
fn receive_response(core: &CoreProcess, timeout: Duration) -> Value {
    loop {
        let message = core.receive(timeout);
        if message.get("id").is_some() {
            return message;
        }
        assert_eq!(message["method"], "doctor/progress", "{message}");
    }
}

#[test]
fn interactive_request_completes_while_doctor_is_running() {
    let (project_root, fifo) = blocked_locale_project();
    let mut core = CoreProcess::spawn();
    core.initialize(100);

    core.send(&doctor_request(1, &project_root, json!([])));
    let mut writer = wait_for_doctor_reader(&fifo);

    core.send(&scan_request(2));
    let scan_response = receive_response(&core, Duration::from_secs(10));
    assert_ready_scan(&scan_response, 2);

    writer
        .write_all(br#"{"ready":"Ready"}"#)
        .expect("failed to write locale content");
    drop(writer);

    let doctor_response = receive_response(&core, Duration::from_secs(30));
    assert_eq!(doctor_response["id"], 1);
    assert!(doctor_response.get("error").is_none(), "{doctor_response}");
    assert_eq!(doctor_response["result"]["cancelled"], false);

    drop(core);
    let _ = fs::remove_dir_all(project_root);
}

#[test]
fn repeated_doctor_requests_keep_only_the_latest_pending_job() {
    let (blocked_root, fifo) = blocked_locale_project();
    let ready_root = unique_temp_dir();
    let locale_file = ready_root.join("locales/en/common.json");
    fs::create_dir_all(
        locale_file
            .parent()
            .expect("locale file should have a parent"),
    )
    .expect("failed to create locale directory");
    fs::write(&locale_file, r#"{"title":"Title"}"#).expect("failed to write locale file");

    let mut core = CoreProcess::spawn();
    core.initialize(100);

    core.send(&doctor_request(10, &blocked_root, json!([])));
    let writer = wait_for_doctor_reader(&fifo);

    let latest_buffer = json!([{
        "path": ready_root.join("src/app.ts"),
        "source": "t(\"title\");",
        "lang": "typescript"
    }]);
    // The cancelled active job releases the scheduler after a short grace period, so the
    // queued requests must arrive together for the older one to be superseded while pending.
    core.send_batch(&[
        doctor_request(11, &blocked_root, json!([])),
        doctor_request(12, &ready_root, latest_buffer),
        scan_request(13),
    ]);

    let mut responses = HashMap::new();
    while responses.len() < 4 {
        let message = core.receive(Duration::from_secs(30));
        if message.get("method").and_then(Value::as_str) == Some("doctor/progress") {
            assert_eq!(message["params"]["request_id"], 12, "{message}");
            continue;
        }
        let id = message
            .get("id")
            .and_then(Value::as_u64)
            .expect("message should be a response");
        responses.insert(id, message);
    }

    assert_ready_scan(&responses[&13], 13);

    let active = &responses[&10];
    assert_eq!(active["error"]["code"], -32800, "{active}");
    assert_eq!(active["error"]["message"], "doctor request cancelled");
    // The older queued job never completes: it is superseded while pending, or cancelled if a
    // stalled test process let the scheduler start it before the newer request arrived.
    let pending = &responses[&11];
    assert_eq!(pending["error"]["code"], -32800, "{pending}");
    assert!(
        [
            "doctor request superseded by a newer request",
            "doctor request cancelled"
        ]
        .contains(&pending["error"]["message"].as_str().unwrap_or_default()),
        "{pending}"
    );

    let latest = &responses[&12];
    assert!(latest.get("error").is_none(), "{latest}");
    assert_eq!(latest["result"]["cancelled"], false);
    assert_eq!(latest["result"]["used_keys"]["common:title"], true);

    drop(writer);
    drop(core);
    let _ = fs::remove_dir_all(blocked_root);
    let _ = fs::remove_dir_all(ready_root);
}

#[test]
fn doctor_survives_deeply_nested_sources_in_parallel() {
    const DEEP_FILES: usize = 4;
    let project_root = unique_temp_dir();
    let locale_file = project_root.join("locales/en/common.json");
    fs::create_dir_all(
        locale_file
            .parent()
            .expect("locale file should have a parent"),
    )
    .expect("failed to create locale directory");
    let keys: Vec<String> = (0..DEEP_FILES)
        .map(|index| format!("deep{index}"))
        .collect();
    let locale: serde_json::Map<String, Value> = keys
        .iter()
        .map(|key| (key.clone(), Value::String(key.to_uppercase())))
        .collect();
    fs::write(&locale_file, Value::Object(locale).to_string())
        .expect("failed to write locale file");
    let src_dir = project_root.join("src");
    fs::create_dir_all(&src_dir).expect("failed to create source directory");
    // A long member chain nests the AST deeply enough to overflow a default-sized thread stack.
    let deep_chain = ".b".repeat(100_000);
    for (index, key) in keys.iter().enumerate() {
        fs::write(
            src_dir.join(format!("deep{index}.ts")),
            format!("const x = a{deep_chain};\nt(\"{key}\");\n"),
        )
        .expect("failed to write deep source");
    }

    let mut core = CoreProcess::spawn();
    core.initialize(100);
    let mut request = doctor_request(1, &project_root, json!([]));
    request["params"]["deadline_ms"] = json!(120_000);
    core.send(&request);

    let mut analyzed_files = 0;
    let doctor_response = loop {
        let message = core.receive(Duration::from_secs(120));
        if message.get("id").and_then(Value::as_u64) == Some(1) {
            break message;
        }
        if let Some(processed) = message["params"]["file_processed"].as_u64() {
            analyzed_files = processed;
        }
    };
    assert!(doctor_response.get("error").is_none(), "{doctor_response}");
    let result = &doctor_response["result"];
    assert_eq!(result["cancelled"], false);
    assert_eq!(analyzed_files, DEEP_FILES as u64);
    assert_eq!(
        result["issues"],
        json!([]),
        "every deep source should be analyzed without scan failures"
    );
    for key in &keys {
        assert_eq!(
            result["used_keys"][format!("common:{key}")],
            true,
            "{key} should be found in its deep source: {result}"
        );
    }

    core.send(&scan_request(2));
    let scan_response = core.receive(Duration::from_secs(30));
    assert_ready_scan(&scan_response, 2);

    drop(core);
    let _ = fs::remove_dir_all(project_root);
}
