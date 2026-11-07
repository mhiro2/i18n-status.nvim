use anyhow::{Result, anyhow};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::resource::index::{BuildIndexParams, IndexCache, RootConfig};
use crate::scan;
use crate::util::{self, extract_placeholders, placeholder_equal};

/// Upper bound on parallel source-scan workers. Each worker reserves `SERVER_STACK_SIZE` of
/// virtual stack, so the pool stays small instead of following the machine's core count.
const MAX_SCAN_WORKERS: usize = 8;

/// Thread pool for one Doctor run's parallel source analysis. Rayon's global pool uses the
/// default thread stack, which deeply nested source overflows inside swc and aborts the whole
/// process; these workers get the same stack as the server thread so parallel and single-file
/// analysis behave alike. The pool is sized to the workload and released after the run, so its
/// stack reservation never outlives the analysis and a failed start can be retried.
fn scan_pool(file_count: usize) -> Result<rayon::ThreadPool> {
    let workers = std::thread::available_parallelism()
        .map_or(1, usize::from)
        .min(MAX_SCAN_WORKERS)
        .min(file_count.max(1));
    rayon::ThreadPoolBuilder::new()
        .num_threads(workers)
        .stack_size(util::SERVER_STACK_SIZE)
        .thread_name(|index| format!("i18n-status-doctor-scan-{index}"))
        .build()
        .map_err(|err| anyhow!("failed to start doctor scan workers: {err}"))
}

#[derive(Debug, Deserialize)]
pub struct DiagnoseParams {
    pub project_root: String,
    pub roots: Vec<RootConfig>,
    pub primary_lang: String,
    pub languages: Vec<String>,
    pub fallback_namespace: String,
    #[serde(default)]
    pub ignore_patterns: Vec<String>,
    /// Key patterns (same syntax as `ignore_patterns`) declared as used at runtime.
    #[serde(default)]
    pub dynamic_patterns: Vec<String>,
    #[serde(default)]
    pub open_buf_paths: Vec<String>,
    #[serde(default)]
    pub open_buffers: Vec<OpenBuffer>,
    #[serde(default)]
    pub cancel_token_path: Option<String>,
    #[serde(default = "default_deadline_ms")]
    pub deadline_ms: u64,
}

pub const DEFAULT_DEADLINE_MS: u64 = 60_000;

const fn default_deadline_ms() -> u64 {
    DEFAULT_DEADLINE_MS
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
    /// Details of an `unresolved` reference or of the dynamic usage behind `possibly_used`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<IssueReference>,
}

#[derive(Debug, Serialize)]
pub struct IssueReference {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<scan::UnresolvedReason>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expression: Option<String>,
    /// Canonical key prefixes (`unresolved`) or the prefix or declared pattern that matched
    /// (`possibly_used`).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub key_prefixes: Vec<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub unbounded: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub declared_pattern: Option<String>,
}

impl DoctorIssue {
    fn new(kind: &str, message: String, severity: u32) -> Self {
        Self {
            kind: kind.to_string(),
            message,
            severity,
            file: None,
            key: None,
            lnum: None,
            col: None,
            reference: None,
        }
    }
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
    matching_pattern(key, ignore_patterns).is_some()
}

/// First pattern matching `key`. `^` and `$` anchor a pattern to the start or end of the key;
/// otherwise it matches anywhere.
fn matching_pattern<'a>(key: &str, patterns: &'a [String]) -> Option<&'a String> {
    patterns.iter().find(|pattern| {
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

/// A translation call of a scanned file whose key is not statically known.
struct UnresolvedSite {
    file: Option<String>,
    reference: scan::UnresolvedRef,
}

/// Result of scanning a single file
#[derive(Default)]
struct FileResult {
    keys: Vec<String>,
    issues: Vec<DoctorIssue>,
    unresolved: Vec<UnresolvedSite>,
    scan_failed: bool,
}

fn scan_error_issue(file: Option<&str>, message: String) -> DoctorIssue {
    DoctorIssue {
        file: file.map(ToOwned::to_owned),
        ..DoctorIssue::new("scan_error", message, 2)
    }
}

/// A file whose source could not be analyzed; its keys are unknown, so unused detection must
/// not trust the collected key set.
fn scan_failure(file: Option<&str>, message: String) -> FileResult {
    FileResult {
        issues: vec![scan_error_issue(file, message)],
        scan_failed: true,
        ..FileResult::default()
    }
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

fn make_result_with_index(
    issues: Vec<DoctorIssue>,
    used_keys_set: HashSet<String>,
    resource_index: Value,
) -> Value {
    let mut result = make_result(issues, used_keys_set, false);
    if let Some(object) = result.as_object_mut() {
        object.insert("resource_index".to_string(), resource_index);
    }
    result
}

fn process_file(
    file_path: &PathBuf,
    params: &DiagnoseParams,
    index_data: &crate::resource::index::IndexResult,
) -> FileResult {
    let file_str = file_path.to_string_lossy().to_string();
    if params.open_buf_paths.iter().any(|p| p == &file_str) {
        return FileResult::default();
    }
    let source = match std::fs::read_to_string(file_path) {
        Ok(s) => s,
        Err(err) => {
            return scan_failure(Some(&file_str), format!("Failed to read source: {err}"));
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
    let extracted = match scan::extract_calls(scan::ExtractParams {
        source: source.to_string(),
        lang: lang.to_string(),
        fallback_namespace: params.fallback_namespace.clone(),
        range: None,
    }) {
        Ok(extracted) => extracted,
        Err(err) => return scan_failure(file, format!("Failed to analyze source: {}", err)),
    };

    let mut result = FileResult {
        unresolved: extracted
            .unresolved
            .into_iter()
            .map(|reference| UnresolvedSite {
                file: file.map(ToOwned::to_owned),
                reference,
            })
            .collect(),
        ..FileResult::default()
    };
    for item in extracted.items {
        let key = item.key.as_str();
        if should_ignore_key(key, &params.ignore_patterns) {
            continue;
        }
        result.keys.push(key.to_string());

        let primary_entry = index_data
            .index
            .get(&params.primary_lang)
            .and_then(|m| m.get(key));
        let primary_value = primary_entry.and_then(|e| e.value.as_deref());

        let key_path = key.split_once(':').map(|(_, path)| path).unwrap_or(key);
        let is_missing = match primary_value {
            None => true,
            Some(v) => {
                v.is_empty() || v == key || (!item.raw.is_empty() && v == item.raw) || v == key_path
            }
        };

        if is_missing {
            result.issues.push(DoctorIssue {
                file: file.map(|p| p.to_string()),
                key: Some(key.to_string()),
                lnum: Some(item.lnum),
                col: Some(item.col),
                ..DoctorIssue::new(
                    "missing",
                    format!(
                        "Key '{}' is missing in primary language '{}'",
                        key, params.primary_lang
                    ),
                    2,
                )
            });
        } else if let Some(pv) = primary_value {
            let base_ph = extract_placeholders(pv, primary_entry.and_then(|e| e.framework));
            for lang in &params.languages {
                if lang == &params.primary_lang {
                    continue;
                }
                let other_entry = index_data.index.get(lang.as_str()).and_then(|m| m.get(key));

                if let Some(ov) = other_entry.and_then(|e| e.value.as_deref()) {
                    let other_ph = extract_placeholders(ov, other_entry.and_then(|e| e.framework));
                    if !placeholder_equal(&base_ph, &other_ph) {
                        result.issues.push(DoctorIssue {
                            file: file.map(|p| p.to_string()),
                            key: Some(key.to_string()),
                            ..DoctorIssue::new(
                                "mismatch",
                                format!(
                                    "Placeholder mismatch for '{}' between '{}' and '{}'",
                                    key, params.primary_lang, lang
                                ),
                                2,
                            )
                        });
                    }
                }
            }
        }
    }

    result
}

fn unresolved_message(reference: &scan::UnresolvedRef) -> String {
    let what = match reference.reason {
        scan::UnresolvedReason::Dynamic => "is decided at runtime",
        scan::UnresolvedReason::Partial => "is only partially static",
        scan::UnresolvedReason::Limit => "expands to too many keys to enumerate",
    };
    let range = match (reference.key_prefixes.is_empty(), reference.unbounded) {
        (true, _) => "it may be any key".to_string(),
        (false, unbounded) => format!(
            "it may be any key starting with {}{}",
            reference
                .key_prefixes
                .iter()
                .map(|prefix| format!("'{prefix}'"))
                .collect::<Vec<_>>()
                .join(", "),
            if unbounded { " or any other key" } else { "" }
        ),
    };
    format!("Translation key `{}` {what}; {range}", reference.expression)
}

fn unresolved_issue(site: UnresolvedSite) -> DoctorIssue {
    let reference = site.reference;
    DoctorIssue {
        file: site.file,
        lnum: Some(reference.lnum),
        col: Some(reference.col),
        reference: Some(IssueReference {
            reason: Some(reference.reason),
            expression: Some(reference.expression.clone()),
            key_prefixes: reference.key_prefixes.clone(),
            unbounded: reference.unbounded,
            declared_pattern: None,
        }),
        ..DoctorIssue::new("unresolved", unresolved_message(&reference), 3)
    }
}

pub fn diagnose(
    mut params: DiagnoseParams,
    notify: &dyn Fn(&str, Value),
    server_cancelled: &dyn Fn() -> bool,
) -> Result<Value> {
    let cancel_token_path = params.cancel_token_path.clone();
    let is_cancelled_now = || server_cancelled() || is_cancelled(cancel_token_path.as_deref());

    let mut issues: Vec<DoctorIssue> = Vec::new();
    let mut used_keys_set: HashSet<String> = HashSet::new();
    let mut has_scan_failures = false;
    let mut unresolved: Vec<UnresolvedSite> = Vec::new();

    if is_cancelled_now() {
        return Ok(make_result(issues, used_keys_set, true));
    }

    if params.roots.is_empty() {
        issues.push(DoctorIssue::new(
            "resource_root_missing",
            "No resource roots found. Expected locales/, public/locales/, or messages/ directory."
                .to_string(),
            1,
        ));
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
    let index_data: crate::resource::index::IndexResult =
        serde_json::from_value(index_result.clone())?;

    params.languages.clone_from(&index_data.languages);
    if params.primary_lang.is_empty() {
        params.primary_lang = index_data.languages.first().cloned().unwrap_or_default();
    }
    params.fallback_namespace = if index_data.namespaces.len() == 1 {
        index_data.namespaces[0].clone()
    } else if index_data
        .namespaces
        .iter()
        .any(|namespace| namespace == "translation")
    {
        "translation".to_string()
    } else {
        index_data
            .namespaces
            .first()
            .cloned()
            .unwrap_or_else(|| "common".to_string())
    };

    if is_cancelled_now() {
        return Ok(make_result(issues, used_keys_set, true));
    }

    for error in &index_data.errors {
        issues.push(DoctorIssue {
            file: Some(error.file.clone()),
            ..DoctorIssue::new(
                "resource_error",
                format!("Failed to parse {}: {}", error.file, error.error),
                2,
            )
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
        used_keys_set.extend(result.keys);
        unresolved.extend(result.unresolved);
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
        let entry = match entry {
            Ok(entry) => entry,
            Err(err) => {
                // An unreadable directory hides source files, so unused results would be wrong.
                has_scan_failures = true;
                issues.push(scan_error_issue(
                    None,
                    format!("Failed to collect source files: {err}"),
                ));
                continue;
            }
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

    // Process files in parallel batches on a large-stack pool started only when there are files
    let pool = (!source_files.is_empty())
        .then(|| scan_pool(total_files))
        .transpose()?;
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

        let Some(pool) = &pool else {
            break;
        };
        let results: Vec<FileResult> = pool.install(|| {
            chunk
                .par_iter()
                .map(|file_path| process_file(file_path, &params, &index_data))
                .collect()
        });

        for result in results {
            if result.scan_failed {
                has_scan_failures = true;
            }
            used_keys_set.extend(result.keys);
            unresolved.extend(result.unresolved);
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

    // A key without a static reference is only reported unused when no dynamic reference or
    // declared pattern can reach it.
    let mut dynamic_prefixes: Vec<String> = unresolved
        .iter()
        .flat_map(|site| site.reference.key_prefixes.iter().cloned())
        .collect();
    dynamic_prefixes.sort();
    dynamic_prefixes.dedup();
    let unbounded_count = unresolved
        .iter()
        .filter(|site| site.reference.unbounded)
        .count();
    issues.extend(unresolved.into_iter().map(unresolved_issue));

    if has_scan_failures {
        issues.push(DoctorIssue::new(
            "unused_skipped",
            "Skipped unused key detection because one or more source files failed to analyze."
                .to_string(),
            1,
        ));
    } else if let Some(primary_index) = index_data.index.get(&params.primary_lang) {
        let mut has_unused = false;
        for (key, entry) in primary_index {
            if is_cancelled_now() {
                return Ok(make_result(issues, used_keys_set, true));
            }
            if should_ignore_key(key, &params.ignore_patterns) || used_keys_set.contains(key) {
                continue;
            }
            let issue = if let Some(pattern) = matching_pattern(key, &params.dynamic_patterns) {
                DoctorIssue {
                    reference: Some(IssueReference {
                        reason: None,
                        expression: None,
                        key_prefixes: Vec::new(),
                        unbounded: false,
                        declared_pattern: Some(pattern.clone()),
                    }),
                    ..DoctorIssue::new(
                        "possibly_used",
                        format!(
                            "Key '{key}' has no static reference but matches the dynamic key pattern '{pattern}'"
                        ),
                        3,
                    )
                }
            } else if let Some(prefix) = dynamic_prefixes
                .iter()
                .find(|prefix| key.starts_with(prefix.as_str()))
            {
                DoctorIssue {
                    reference: Some(IssueReference {
                        reason: None,
                        expression: None,
                        key_prefixes: vec![prefix.clone()],
                        unbounded: false,
                        declared_pattern: None,
                    }),
                    ..DoctorIssue::new(
                        "possibly_used",
                        format!(
                            "Key '{key}' has no static reference but may be used by a dynamic key starting with '{prefix}'"
                        ),
                        3,
                    )
                }
            } else {
                has_unused = true;
                DoctorIssue::new(
                    "unused",
                    format!("Key '{}' exists in resources but is not used in code", key),
                    3,
                )
            };
            issues.push(DoctorIssue {
                file: entry.file.clone(),
                key: Some(key.clone()),
                ..issue
            });
        }
        if has_unused && unbounded_count > 0 {
            issues.push(DoctorIssue::new(
                "unused_uncertain",
                format!(
                    "{unbounded_count} translation call(s) use keys that cannot be narrowed statically; keys reported as unused may still be used at runtime."
                ),
                1,
            ));
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
                        key: Some(key.clone()),
                        ..DoctorIssue::new(
                            "drift_missing",
                            format!(
                                "Key '{}' exists in '{}' but is missing in '{}'",
                                key, params.primary_lang, lang
                            ),
                            3,
                        )
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
                            key: Some(key.clone()),
                            ..DoctorIssue::new(
                                "drift_extra",
                                format!(
                                    "Key '{}' exists in '{}' but not in primary '{}'",
                                    key, lang, params.primary_lang
                                ),
                                3,
                            )
                        });
                    }
                }
            }
        }
    }

    Ok(make_result_with_index(issues, used_keys_set, index_result))
}
