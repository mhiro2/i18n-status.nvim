use i18n_status_core::contract::{CLIENT_NAME, CORE_NAME, CORE_VERSION, PROTOCOL_VERSION};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
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
        let stdin = self.stdin();
        writeln!(stdin, "{request}").expect("failed to send request");
        stdin.flush().expect("failed to flush request");
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
    let path = std::env::temp_dir().join(format!(
        "i18n-status-core-rpc-concurrency-{}-{}",
        std::process::id(),
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

#[test]
fn interactive_request_completes_while_doctor_is_running() {
    let project_root = unique_temp_dir();
    let locale_file = project_root.join("locales/en/common.json");
    fs::create_dir_all(
        locale_file
            .parent()
            .expect("locale file should have a parent"),
    )
    .expect("failed to create locale directory");
    fs::write(&locale_file, r#"{"title":"Title"}"#).expect("failed to write locale file");

    let mut core = CoreProcess::spawn();
    core.initialize(100);
    let source = "const value = { nested: true };\n".repeat(100_000);
    let doctor_request = json!({
        "jsonrpc": "2.0",
        "id": 1,
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
            "open_buffers": [{
                "path": project_root.join("src/slow.ts"),
                "source": source,
                "lang": "typescript"
            }]
        }
    });

    core.send(&doctor_request);
    core.send(&scan_request(2));

    let first_response_id = loop {
        let message = core.receive(Duration::from_secs(30));
        if let Some(id) = message.get("id").and_then(Value::as_u64) {
            break id;
        }
    };

    assert_eq!(
        first_response_id, 2,
        "interactive scan must not wait for the earlier doctor request"
    );

    drop(core);
    let _ = fs::remove_dir_all(project_root);
}

#[test]
fn repeated_doctor_requests_keep_only_the_latest_pending_job() {
    let project_root = unique_temp_dir();
    let locale_file = project_root.join("locales/en/common.json");
    fs::create_dir_all(
        locale_file
            .parent()
            .expect("locale file should have a parent"),
    )
    .expect("failed to create locale directory");
    fs::write(&locale_file, r#"{"title":"Title"}"#).expect("failed to write locale file");

    let mut core = CoreProcess::spawn();
    core.initialize(100);
    let slow_source = "const value = { nested: true };\n".repeat(100_000);
    let doctor_request = |id: u64, source: &str| {
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
                "open_buffers": [{
                    "path": project_root.join(format!("src/slow-{id}.ts")),
                    "source": source,
                    "lang": "typescript"
                }]
            }
        })
    };

    for request in [
        doctor_request(10, &slow_source),
        doctor_request(11, &slow_source),
        doctor_request(12, "t(\"title\");"),
        scan_request(13),
    ] {
        core.send(&request);
    }

    let mut responses = HashMap::new();
    let mut response_order = Vec::new();
    while responses.len() < 4 {
        let message = core.receive(Duration::from_secs(30));
        if message.get("method").and_then(Value::as_str) == Some("doctor/progress") {
            let request_id = message["params"]["request_id"]
                .as_u64()
                .expect("doctor progress should identify its request");
            assert!((10..=12).contains(&request_id));
            continue;
        }
        let Some(id) = message.get("id").and_then(Value::as_u64) else {
            continue;
        };
        response_order.push(id);
        responses.insert(id, message);
    }

    assert!(
        response_order.iter().position(|id| *id == 13)
            < response_order.iter().position(|id| *id == 12),
        "interactive RPC must complete before the retained doctor job"
    );
    assert_eq!(responses[&12]["result"]["cancelled"], false);
    for id in [10, 11] {
        let response = &responses[&id];
        let cancelled = response["result"]["cancelled"].as_bool() == Some(true);
        let superseded = response["error"]["code"].as_i64() == Some(-32800);
        assert!(
            cancelled || superseded,
            "older doctor request {id} should not finish normally: {response}"
        );
    }

    drop(core);
    let _ = fs::remove_dir_all(project_root);
}
