use anyhow::Result;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::resource::index::{BuildIndexParams, IndexCache, RootConfig};
use crate::scan;
use crate::util::{extract_placeholders, placeholder_equal};

#[derive(Debug, Deserialize)]
pub struct DiagnoseParams {
    pub project_root: String,
    pub roots: Vec<RootConfig>,
    pub primary_lang: String,
    pub languages: Vec<String>,
    pub fallback_namespace: String,
    #[serde(default)]
    pub ignore_patterns: Vec<String>,
    #[serde(default)]
    pub open_buf_paths: Vec<String>,
    #[serde(default)]
    pub open_buffers: Vec<OpenBuffer>,
    #[serde(default)]
    pub cancel_token_path: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct OpenBuffer {
    #[serde(default)]
    pub path: Option<String>,
    pub source: String,
    pub lang: String,
}

#[derive(Debug, Serialize)]
pub struct DoctorIssue {
    pub kind: String,
    pub message: String,
    pub severity: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lnum: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub col: Option<u32>,
}

fn is_js_ts_file(path: &std::path::Path) -> bool {
    matches!(
        path.extension().and_then(|e| e.to_str()),
        Some("js" | "jsx" | "ts" | "tsx" | "mjs" | "cjs" | "mts" | "cts")
    )
}

fn lang_from_extension(path: &std::path::Path) -> &str {
    match path.extension().and_then(|e| e.to_str()) {
        Some("tsx") => "tsx",
        Some("jsx") => "jsx",
        Some("ts" | "mts" | "cts") => "typescript",
        _ => "javascript",
    }
}

fn should_ignore_key(key: &str, ignore_patterns: &[String]) -> bool {
    ignore_patterns.iter().any(|pattern| {
        if pattern.is_empty() {
            return false;
        }
        let anchored_start = pattern.starts_with('^');
        let anchored_end = pattern.ends_with('$');
        let start = if anchored_start { 1 } else { 0 };
        let end = if anchored_end {
            pattern.len().saturating_sub(1)
        } else {
            pattern.len()
        };
        let needle = &pattern[start..end];
        if anchored_start && anchored_end {
            key == needle
        } else if anchored_start {
            key.starts_with(needle)
        } else if anchored_end {
            key.ends_with(needle)
        } else {
            key.contains(needle)
        }
    })
}

/// Result of scanning a single file
struct FileResult {
    keys: Vec<String>,
    issues: Vec<DoctorIssue>,
    scan_failed: bool,
}

fn is_cancelled(token_path: Option<&str>) -> bool {
    match token_path {
        Some(path) if !path.is_empty() => Path::new(path).exists(),
        _ => false,
    }
}

fn make_result(issues: Vec<DoctorIssue>, used_keys_set: HashSet<String>, cancelled: bool) -> Value {
    let used_keys_map: HashMap<String, bool> =
        used_keys_set.into_iter().map(|k| (k, true)).collect();
    serde_json::json!({
        "issues": issues,
        "used_keys": used_keys_map,
        "cancelled": cancelled
    })
}

fn process_file(
    file_path: &PathBuf,
    params: &DiagnoseParams,
    index_data: &crate::resource::index::IndexResult,
) -> FileResult {
    let file_str = file_path.to_string_lossy().to_string();
    if params.open_buf_paths.iter().any(|p| p == &file_str) {
        return FileResult {
            keys: Vec::new(),
            issues: Vec::new(),
            scan_failed: false,
        };
    }
    let source = match std::fs::read_to_string(file_path) {
        Ok(s) => s,
        Err(_) => {
            return FileResult {
                keys: Vec::new(),
                issues: Vec::new(),
                scan_failed: false,
            };
        }
    };
    let lang = lang_from_extension(file_path);
    process_source(&source, lang, Some(&file_str), params, index_data)
}

fn process_source(
    source: &str,
    lang: &str,
    file: Option<&str>,
    params: &DiagnoseParams,
    index_data: &crate::resource::index::IndexResult,
) -> FileResult {
    let mut keys = Vec::new();
    let mut issues = Vec::new();
    let extracted = scan::extract(scan::ExtractParams {
        source: source.to_string(),
        lang: lang.to_string(),
        fallback_namespace: params.fallback_namespace.clone(),
        range: None,
    });

    if let Err(err) = &extracted {
        issues.push(DoctorIssue {
            kind: "scan_error".to_string(),
            message: format!("Failed to analyze source: {}", err),
            severity: 2,
            file: file.map(|p| p.to_string()),
            key: None,
            lnum: None,
            col: None,
        });
        return FileResult {
            keys,
            issues,
            scan_failed: true,
        };
    }

    if let Ok(result) = extracted {
        if let Some(items) = result.get("items").and_then(|v| v.as_array()) {
            for item in items {
                if let Some(key) = item.get("key").and_then(|v| v.as_str()) {
                    if should_ignore_key(key, &params.ignore_patterns) {
                        continue;
                    }
                    keys.push(key.to_string());

                    let primary_value = index_data
                        .index
                        .get(&params.primary_lang)
                        .and_then(|m| m.get(key))
                        .and_then(|e| e.value.as_deref());

                    let raw = item.get("raw").and_then(|v| v.as_str()).unwrap_or("");
                    let key_path = key.split_once(':').map(|(_, path)| path).unwrap_or(key);
                    let is_missing = match primary_value {
                        None => true,
                        Some(v) => {
                            v.is_empty()
                                || v == key
                                || (!raw.is_empty() && v == raw)
                                || v == key_path
                        }
                    };

                    if is_missing {
                        let lnum = item.get("lnum").and_then(|v| v.as_u64()).map(|v| v as u32);
                        let col = item.get("col").and_then(|v| v.as_u64()).map(|v| v as u32);

                        issues.push(DoctorIssue {
                            kind: "missing".to_string(),
                            message: format!(
                                "Key '{}' is missing in primary language '{}'",
                                key, params.primary_lang
                            ),
                            severity: 2,
                            file: file.map(|p| p.to_string()),
                            key: Some(key.to_string()),
                            lnum,
                            col,
                        });
                    } else if let Some(pv) = primary_value {
                        let base_ph = extract_placeholders(pv);
                        for lang in &params.languages {
                            if lang == &params.primary_lang {
                                continue;
                            }
                            let other_value = index_data
                                .index
                                .get(lang.as_str())
                                .and_then(|m| m.get(key))
                                .and_then(|e| e.value.as_deref());

                            if let Some(ov) = other_value {
                                let other_ph = extract_placeholders(ov);
                                if !placeholder_equal(&base_ph, &other_ph) {
                                    issues.push(DoctorIssue {
                                        kind: "mismatch".to_string(),
                                        message: format!(
                                            "Placeholder mismatch for '{}' between '{}' and '{}'",
                                            key, params.primary_lang, lang
                                        ),
                                        severity: 2,
                                        file: file.map(|p| p.to_string()),
                                        key: Some(key.to_string()),
                                        lnum: None,
                                        col: None,
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    FileResult {
        keys,
        issues,
        scan_failed: false,
    }
}

pub fn diagnose(params: DiagnoseParams, notify: &dyn Fn(&str, Value)) -> Result<Value> {
    let cancel_token_path = params.cancel_token_path.clone();
    let is_cancelled_now = || is_cancelled(cancel_token_path.as_deref());

    let mut issues: Vec<DoctorIssue> = Vec::new();
    let mut used_keys_set: HashSet<String> = HashSet::new();
    let mut has_scan_failures = false;

    if is_cancelled_now() {
        return Ok(make_result(issues, used_keys_set, true));
    }

    if params.roots.is_empty() {
        issues.push(DoctorIssue {
            kind: "resource_root_missing".to_string(),
            message: "No resource roots found. Expected locales/, public/locales/, or messages/ directory.".to_string(),
            severity: 1,
            file: None,
            key: None,
            lnum: None,
            col: None,
        });
        return Ok(make_result(issues, used_keys_set, false));
    }

    // Build resource index
    let cache = IndexCache::new();
    let index_result = crate::resource::index::build_index(
        BuildIndexParams {
            roots: params.roots.clone(),
        },
        &cache,
    )?;
    let index_data: crate::resource::index::IndexResult = serde_json::from_value(index_result)?;

    if is_cancelled_now() {
        return Ok(make_result(issues, used_keys_set, true));
    }

    for error in &index_data.errors {
        issues.push(DoctorIssue {
            kind: "resource_error".to_string(),
            message: format!("Failed to parse {}: {}", error.file, error.error),
            severity: 2,
            file: Some(error.file.clone()),
            key: None,
            lnum: None,
            col: None,
        });
    }

    for open_buf in &params.open_buffers {
        if is_cancelled_now() {
            return Ok(make_result(issues, used_keys_set, true));
        }
        if open_buf.source.is_empty() {
            continue;
        }
        let lang = if !open_buf.lang.is_empty() {
            open_buf.lang.as_str()
        } else if let Some(path) = open_buf.path.as_deref() {
            lang_from_extension(Path::new(path))
        } else {
            "javascript"
        };
        let result = process_source(
            &open_buf.source,
            lang,
            open_buf.path.as_deref(),
            &params,
            &index_data,
        );
        if result.scan_failed {
            has_scan_failures = true;
        }
        for key in result.keys {
            used_keys_set.insert(key);
        }
        issues.extend(result.issues);
    }

    // Collect source files
    let project_root = PathBuf::from(&params.project_root);
    let mut source_files: Vec<PathBuf> = Vec::new();

    notify(
        "doctor/progress",
        serde_json::json!({
            "message": "collecting source files..."
        }),
    );

    let builder = ignore::WalkBuilder::new(&project_root);
    for (discovered_entries, entry) in builder.build().enumerate() {
        if is_cancelled_now() {
            notify(
                "doctor/progress",
                serde_json::json!({
                    "message": format!("cancelled while collecting files ({} entries checked)", discovered_entries),
                    "file_processed": 0,
                    "file_total": 0
                }),
            );
            return Ok(make_result(issues, used_keys_set, true));
        }
        if discovered_entries > 0 && discovered_entries % 500 == 0 {
            notify(
                "doctor/progress",
                serde_json::json!({
                    "message": format!("collecting source files... {} entries", discovered_entries)
                }),
            );
        }
        let Ok(entry) = entry else {
            continue;
        };
        let path = entry.path();
        if path.is_file() && is_js_ts_file(path) {
            source_files.push(path.to_path_buf());
        }
    }

    let total_files = source_files.len();

    notify(
        "doctor/progress",
        serde_json::json!({
            "message": format!("scanning {} files...", total_files),
            "file_processed": 0,
            "file_total": total_files
        }),
    );

    // Process files in parallel batches using rayon
    let batch_size = 50;
    let mut processed = 0usize;

    for chunk in source_files.chunks(batch_size) {
        if is_cancelled_now() {
            notify(
                "doctor/progress",
                serde_json::json!({
                    "message": format!("cancelled at {}/{} files", processed, total_files),
                    "file_processed": processed,
                    "file_total": total_files
                }),
            );
            return Ok(make_result(issues, used_keys_set, true));
        }

        let results: Vec<FileResult> = chunk
            .par_iter()
            .map(|file_path| process_file(file_path, &params, &index_data))
            .collect();

        for result in results {
            if result.scan_failed {
                has_scan_failures = true;
            }
            for key in result.keys {
                used_keys_set.insert(key);
            }
            issues.extend(result.issues);
        }

        processed += chunk.len();
        notify(
            "doctor/progress",
            serde_json::json!({
                "message": format!("analyzing {}/{} files...", processed, total_files),
                "file_processed": processed,
                "file_total": total_files
            }),
        );
    }

    // Check for unused keys
    if has_scan_failures {
        issues.push(DoctorIssue {
            kind: "unused_skipped".to_string(),
            message:
                "Skipped unused key detection because one or more source files failed to analyze."
                    .to_string(),
            severity: 1,
            file: None,
            key: None,
            lnum: None,
            col: None,
        });
    } else if let Some(primary_index) = index_data.index.get(&params.primary_lang) {
        for (key, entry) in primary_index {
            if is_cancelled_now() {
                return Ok(make_result(issues, used_keys_set, true));
            }
            if should_ignore_key(key, &params.ignore_patterns) {
                continue;
            }
            if !used_keys_set.contains(key) {
                issues.push(DoctorIssue {
                    kind: "unused".to_string(),
                    message: format!("Key '{}' exists in resources but is not used in code", key),
                    severity: 3,
                    file: entry.file.clone(),
                    key: Some(key.clone()),
                    lnum: None,
                    col: None,
                });
            }
        }
    }

    // Check for drift
    if let Some(primary_index) = index_data.index.get(&params.primary_lang) {
        for lang in &params.languages {
            if is_cancelled_now() {
                return Ok(make_result(issues, used_keys_set, true));
            }
            if lang == &params.primary_lang {
                continue;
            }
            let other_index = index_data.index.get(lang.as_str());

            for key in primary_index.keys() {
                if is_cancelled_now() {
                    return Ok(make_result(issues, used_keys_set, true));
                }
                if should_ignore_key(key, &params.ignore_patterns) {
                    continue;
                }
                let has_value = other_index
                    .and_then(|m| m.get(key))
                    .and_then(|e| e.value.as_deref())
                    .map(|v| !v.is_empty())
                    .unwrap_or(false);

                if !has_value {
                    issues.push(DoctorIssue {
                        kind: "drift_missing".to_string(),
                        message: format!(
                            "Key '{}' exists in '{}' but is missing in '{}'",
                            key, params.primary_lang, lang
                        ),
                        severity: 3,
                        file: None,
                        key: Some(key.clone()),
                        lnum: None,
                        col: None,
                    });
                }
            }

            if let Some(other) = other_index {
                for key in other.keys() {
                    if is_cancelled_now() {
                        return Ok(make_result(issues, used_keys_set, true));
                    }
                    if should_ignore_key(key, &params.ignore_patterns) {
                        continue;
                    }
                    if !primary_index.contains_key(key) {
                        issues.push(DoctorIssue {
                            kind: "drift_extra".to_string(),
                            message: format!(
                                "Key '{}' exists in '{}' but not in primary '{}'",
                                key, lang, params.primary_lang
                            ),
                            severity: 3,
                            file: None,
                            key: Some(key.clone()),
                            lnum: None,
                            col: None,
                        });
                    }
                }
            }
        }
    }

    Ok(make_result(issues, used_keys_set, false))
}
