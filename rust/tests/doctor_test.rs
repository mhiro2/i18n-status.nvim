use i18n_status_core::doctor::{self, DiagnoseParams};
use i18n_status_core::resource::index::RootConfig;
use std::fs;
use std::path::PathBuf;
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
