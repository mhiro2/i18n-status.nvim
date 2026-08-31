use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
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
    let initialize_request = json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "initialize",
        "params": {}
    });

    let stdin = child.0.stdin.as_mut().expect("stdin should be piped");
    writeln!(stdin, "{doctor_request}").expect("failed to send doctor request");
    writeln!(stdin, "{initialize_request}").expect("failed to send initialize request");
    stdin.flush().expect("failed to flush requests");

    let first_response_id = loop {
        let line = line_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("core should respond while doctor is running");
        let message: Value = serde_json::from_str(&line).expect("stdout should contain JSON-RPC");
        if let Some(id) = message.get("id").and_then(Value::as_u64) {
            break id;
        }
    };

    assert_eq!(
        first_response_id, 2,
        "initialize must not wait for the earlier doctor request"
    );

    drop(child);
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
    let requests = [
        doctor_request(10, &slow_source),
        doctor_request(11, &slow_source),
        doctor_request(12, "t(\"title\");"),
        json!({
            "jsonrpc": "2.0",
            "id": 13,
            "method": "initialize",
            "params": {}
        }),
    ];

    let stdin = child.0.stdin.as_mut().expect("stdin should be piped");
    for request in requests {
        writeln!(stdin, "{request}").expect("failed to send request");
    }
    stdin.flush().expect("failed to flush requests");

    let mut responses = std::collections::HashMap::new();
    let mut response_order = Vec::new();
    while responses.len() < 4 {
        let line = line_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("all bounded doctor requests should complete");
        let message: Value = serde_json::from_str(&line).expect("stdout should contain JSON-RPC");
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

    drop(child);
    let _ = fs::remove_dir_all(project_root);
}
