use i18n_status_core::doctor::{self, DiagnoseParams};
use i18n_status_core::resource::index::RootConfig;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

fn unique_temp_path(prefix: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after unix epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "i18n-status-core-{}-{}-{}.cancel",
        prefix,
        std::process::id(),
        nanos
    ))
}

fn unique_temp_dir(prefix: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "i18n-status-core-{}-{}-{}",
        prefix,
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after unix epoch")
            .as_nanos()
    ));
    fs::create_dir_all(&dir).expect("failed to create temp directory");
    dir
}

fn write_file(path: &PathBuf, content: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("failed to create parent directory");
    }
    fs::write(path, content).expect("failed to write file");
}

#[test]
fn diagnose_marks_cancelled_when_token_file_exists() {
    let token_path = unique_temp_path("doctor");
    fs::write(&token_path, "1").expect("failed to create cancel token file");

    let params = DiagnoseParams {
        project_root: ".".to_string(),
        roots: vec![RootConfig {
            kind: "i18next".to_string(),
            path: ".".to_string(),
        }],
        primary_lang: "en".to_string(),
        languages: vec!["en".to_string()],
        fallback_namespace: "translation".to_string(),
        ignore_patterns: vec![],
        open_buf_paths: vec![],
        open_buffers: vec![],
        cancel_token_path: Some(token_path.to_string_lossy().to_string()),
    };

    let result = doctor::diagnose(params, &|_, _| {}).expect("diagnose should succeed");
    assert_eq!(result["cancelled"], true);
    assert_eq!(result["issues"].as_array().map(|v| v.len()), Some(0));

    let _ = fs::remove_file(token_path);
}

#[test]
fn diagnose_without_cancel_token_keeps_normal_result() {
    let params = DiagnoseParams {
        project_root: ".".to_string(),
        roots: vec![],
        primary_lang: "en".to_string(),
        languages: vec!["en".to_string()],
        fallback_namespace: "translation".to_string(),
        ignore_patterns: vec![],
        open_buf_paths: vec![],
        open_buffers: vec![],
        cancel_token_path: None,
    };

    let result = doctor::diagnose(params, &|_, _| {}).expect("diagnose should succeed");
    assert_eq!(result["cancelled"], false);
    let issues = result["issues"]
        .as_array()
        .expect("issues should be an array");
    assert_eq!(issues.len(), 1);
    assert_eq!(issues[0]["kind"], "resource_root_missing");
}

#[test]
fn diagnose_reports_scan_error_and_skips_unused_when_parse_fails() {
    let root = unique_temp_dir("doctor-scan-error");
    let locales_dir = root.join("locales");
    let src_dir = root.join("src");
    let en_common = locales_dir.join("en/common.json");
    let broken_source = src_dir.join("broken.ts");

    write_file(&en_common, r#"{"used":"Used","unused":"Unused"}"#);
    write_file(&broken_source, "const broken = (\n");

    let params = DiagnoseParams {
        project_root: root.to_string_lossy().to_string(),
        roots: vec![RootConfig {
            kind: "i18next".to_string(),
            path: locales_dir.to_string_lossy().to_string(),
        }],
        primary_lang: "en".to_string(),
        languages: vec!["en".to_string()],
        fallback_namespace: "common".to_string(),
        ignore_patterns: vec![],
        open_buf_paths: vec![],
        open_buffers: vec![],
        cancel_token_path: None,
    };

    let result = doctor::diagnose(params, &|_, _| {}).expect("diagnose should succeed");
    let issues = result["issues"]
        .as_array()
        .expect("issues should be an array");

    let has_scan_error = issues
        .iter()
        .any(|issue| issue["kind"].as_str() == Some("scan_error"));
    let has_unused_skipped = issues
        .iter()
        .any(|issue| issue["kind"].as_str() == Some("unused_skipped"));
    let has_unused = issues
        .iter()
        .any(|issue| issue["kind"].as_str() == Some("unused"));

    assert!(has_scan_error, "scan_error issue should be reported");
    assert!(
        has_unused_skipped,
        "unused_skipped issue should be reported when scanning fails"
    );
    assert!(
        !has_unused,
        "unused should not be reported after scan failure"
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn diagnose_cancels_during_file_collection() {
    let root = unique_temp_dir("doctor-cancel-collect");
    let locales_dir = root.join("locales");
    let src_dir = root.join("src");
    let en_common = locales_dir.join("en/common.json");
    let source_file = src_dir.join("app.ts");
    let token_path = unique_temp_path("doctor-collect");

    write_file(&en_common, r#"{"used":"Used"}"#);
    write_file(&source_file, r#"t("common:used");"#);

    let params = DiagnoseParams {
        project_root: root.to_string_lossy().to_string(),
        roots: vec![RootConfig {
            kind: "i18next".to_string(),
            path: locales_dir.to_string_lossy().to_string(),
        }],
        primary_lang: "en".to_string(),
        languages: vec!["en".to_string()],
        fallback_namespace: "common".to_string(),
        ignore_patterns: vec![],
        open_buf_paths: vec![],
        open_buffers: vec![],
        cancel_token_path: Some(token_path.to_string_lossy().to_string()),
    };

    let wrote_token = AtomicBool::new(false);
    let result = doctor::diagnose(params, &|method, payload| {
        if method != "doctor/progress" {
            return;
        }
        let Some(message) = payload.get("message").and_then(|v| v.as_str()) else {
            return;
        };
        if !message.contains("collecting source files") {
            return;
        }
        if wrote_token.swap(true, Ordering::SeqCst) {
            return;
        }
        fs::write(&token_path, "1").expect("failed to create cancel token");
    })
    .expect("diagnose should succeed");

    assert_eq!(result["cancelled"], true);

    let _ = fs::remove_file(token_path);
    let _ = fs::remove_dir_all(root);
}
