use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

use crate::util::extract_placeholders;

#[derive(Debug, Deserialize)]
pub struct ComputeParams {
    pub items: Vec<ScanItemInput>,
    pub primary_lang: String,
    pub languages: Vec<String>,
    /// lang -> canonical_key -> { value, file, priority }
    pub index: HashMap<String, HashMap<String, ResourceItemInput>>,
    #[serde(default)]
    pub current_lang: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ScanItemInput {
    pub key: String,
    pub raw: String,
    pub namespace: String,
    #[allow(dead_code)]
    #[serde(default)]
    pub fallback: bool,
}

#[derive(Debug, Deserialize)]
pub struct ResourceItemInput {
    pub value: Option<String>,
    pub file: Option<String>,
    #[allow(dead_code)]
    #[serde(default)]
    pub priority: u32,
}

#[derive(Debug, Serialize)]
pub struct ResolvedItem {
    pub key: String,
    pub text: String,
    pub status: String,
    pub hover: HoverInfo,
}

#[derive(Debug, Serialize)]
pub struct HoverInfo {
    pub key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub primary_lang: String,
    pub display_lang: String,
    pub focus_lang: String,
    pub lang_order: Vec<String>,
    pub values: HashMap<String, HoverValue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub missing_langs: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub localized_langs: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mismatch_langs: Option<Vec<String>>,
}

#[derive(Debug, Serialize)]
pub struct HoverValue {
    pub value: Option<String>,
    pub file: Option<String>,
    pub missing: bool,
}

/// Check if a value is considered "missing"
fn is_missing(value: Option<&str>, key: &str, raw: &str) -> bool {
    match value {
        None => true,
        Some(v) => {
            if v.is_empty() {
                return true;
            }
            if v == raw {
                return true;
            }
            if v == key {
                return true;
            }
            // Check against key path (after namespace colon)
            if let Some(key_path) = key.split_once(':').map(|(_, path)| path) {
                if v == key_path {
                    return true;
                }
            }
            false
        }
    }
}

pub fn compute(params: ComputeParams) -> Result<Value> {
    let mut resolved = Vec::new();

    let primary = &params.primary_lang;
    let display_lang = params.current_lang.as_deref().unwrap_or(primary);

    // Build lang_order: primary first, then others
    let mut lang_order = vec![primary.clone()];
    for lang in &params.languages {
        if lang != primary {
            lang_order.push(lang.clone());
        }
    }

    let compare_langs: Vec<&String> = params
        .languages
        .iter()
        .filter(|l| l.as_str() != primary)
        .collect();

    for item in &params.items {
        let key = &item.key;

        // Get primary value
        let primary_entry = params.index.get(primary).and_then(|m| m.get(key.as_str()));
        let primary_value = primary_entry.and_then(|e| e.value.as_deref());

        // Get display value
        let display_entry = params
            .index
            .get(display_lang)
            .and_then(|m| m.get(key.as_str()));
        let display_value = display_entry
            .and_then(|e| e.value.as_deref())
            .or(primary_value);

        let missing_primary = is_missing(primary_value, key, &item.raw);

        // Build hover values and compute status
        let mut values = HashMap::new();
        values.insert(
            primary.clone(),
            HoverValue {
                value: primary_value.map(|s| s.to_string()),
                file: primary_entry.and_then(|e| e.file.clone()),
                missing: missing_primary,
            },
        );

        let mut any_missing = false;
        let mut any_localized = false;
        let mut missing_langs = Vec::new();
        let mut localized_langs = Vec::new();
        let mut mismatch_langs = Vec::new();

        // Collect compare items for placeholder check
        let mut compare_values: Vec<(&str, &str)> = Vec::new(); // (lang, value)

        for lang in &compare_langs {
            let entry = params
                .index
                .get(lang.as_str())
                .and_then(|m| m.get(key.as_str()));
            let value = entry.and_then(|e| e.value.as_deref());
            let missing = is_missing(value, key, &item.raw);

            values.insert(
                lang.to_string(),
                HoverValue {
                    value: value.map(|s| s.to_string()),
                    file: entry.and_then(|e| e.file.clone()),
                    missing,
                },
            );

            if missing {
                any_missing = true;
                missing_langs.push(lang.to_string());
            } else if let Some(pv) = primary_value {
                if let Some(v) = value {
                    if v != pv {
                        any_localized = true;
                        localized_langs.push(lang.to_string());
                    }
                    compare_values.push((lang, v));
                }
            }
        }

        // Determine status
        let status;
        let reason;

        if missing_primary {
            status = "\u{00d7}"; // ×
            reason = Some("missing_primary");
        } else {
            // Check placeholder mismatches
            let base_placeholders = extract_placeholders(primary_value.unwrap_or(""));
            let mut has_mismatch = false;
            for (lang, value) in &compare_values {
                let current_placeholders = extract_placeholders(value);
                if !placeholder_equal_vecs(&base_placeholders, &current_placeholders) {
                    has_mismatch = true;
                    mismatch_langs.push(lang.to_string());
                }
            }

            if has_mismatch {
                status = "!";
                reason = Some("placeholder_mismatch");
            } else if any_missing {
                status = "?";
                reason = Some("fallback");
            } else if any_localized {
                status = "\u{2260}"; // ≠
                reason = Some("localized");
            } else {
                status = "=";
                reason = None;
            }
        };

        let hover = HoverInfo {
            key: key.clone(),
            namespace: Some(item.namespace.clone()),
            status: Some(status.to_string()),
            reason: reason.map(|r| r.to_string()),
            primary_lang: primary.clone(),
            display_lang: display_lang.to_string(),
            focus_lang: display_lang.to_string(),
            lang_order: lang_order.clone(),
            values,
            missing_langs: if missing_langs.is_empty() {
                None
            } else {
                Some(missing_langs)
            },
            localized_langs: if localized_langs.is_empty() {
                None
            } else {
                Some(localized_langs)
            },
            mismatch_langs: if mismatch_langs.is_empty() {
                None
            } else {
                Some(mismatch_langs)
            },
        };

        resolved.push(ResolvedItem {
            key: key.clone(),
            text: display_value.unwrap_or("").to_string(),
            status: status.to_string(),
            hover,
        });
    }

    Ok(serde_json::json!({ "resolved": resolved }))
}

fn placeholder_equal_vecs(a: &[String], b: &[String]) -> bool {
    a == b
}
