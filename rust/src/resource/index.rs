use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use super::io::{file_mtime, read_json_file};
use crate::util::flatten_table;

#[derive(Debug, Deserialize)]
pub struct BuildIndexParams {
    pub roots: Vec<RootConfig>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RootConfig {
    pub kind: String,
    pub path: String,
}

#[derive(Debug, Deserialize)]
pub struct ApplyChangesParams {
    pub cache_key: String,
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceItem {
    pub value: Option<String>,
    pub file: Option<String>,
    pub priority: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexError {
    pub lang: String,
    pub file: String,
    pub error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexResult {
    /// lang -> canonical_key -> ResourceItem
    pub index: HashMap<String, HashMap<String, ResourceItem>>,
    /// file path -> mtime
    pub files: HashMap<String, u64>,
    pub languages: Vec<String>,
    pub errors: Vec<IndexError>,
    pub namespaces: Vec<String>,
}

/// In-process cache for resource indices.
pub struct IndexCache {
    entries: Mutex<HashMap<String, IndexResult>>,
}

impl IndexCache {
    pub fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
        }
    }

    fn get(&self, key: &str) -> Option<IndexResult> {
        self.entries.lock().unwrap().get(key).cloned()
    }

    fn set(&self, key: String, value: IndexResult) {
        self.entries.lock().unwrap().insert(key, value);
    }
}

impl Default for IndexCache {
    fn default() -> Self {
        Self::new()
    }
}

/// Insert items into the index. Only replaces if the new priority is lower (wins).
fn insert_items(
    index: &mut HashMap<String, HashMap<String, ResourceItem>>,
    lang: &str,
    namespace: &str,
    flat: &std::collections::BTreeMap<String, String>,
    file_path: &str,
    priority: u32,
) {
    let lang_map = index.entry(lang.to_string()).or_default();
    for (key, value) in flat {
        let canonical_key = format!("{}:{}", namespace, key);
        let entry = lang_map.entry(canonical_key);
        match entry {
            std::collections::hash_map::Entry::Vacant(e) => {
                e.insert(ResourceItem {
                    value: Some(value.clone()),
                    file: Some(file_path.to_string()),
                    priority,
                });
            }
            std::collections::hash_map::Entry::Occupied(mut e) => {
                if priority < e.get().priority {
                    e.insert(ResourceItem {
                        value: Some(value.clone()),
                        file: Some(file_path.to_string()),
                        priority,
                    });
                }
            }
        }
    }
}

/// Process an i18next root: locales/{lang}/{ns}.json
fn process_i18next(
    root: &Path,
    index: &mut HashMap<String, HashMap<String, ResourceItem>>,
    files: &mut HashMap<String, u64>,
    languages: &mut BTreeSet<String>,
    namespaces: &mut BTreeSet<String>,
    errors: &mut Vec<IndexError>,
) {
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let lang = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };
        let mut has_json_file = false;

        let lang_entries = match std::fs::read_dir(&path) {
            Ok(e) => e,
            Err(_) => continue,
        };

        for file_entry in lang_entries.flatten() {
            let file_path = file_entry.path();
            if file_path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            has_json_file = true;
            let ns = match file_path.file_stem().and_then(|n| n.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            namespaces.insert(ns.clone());

            let file_str = file_path.to_string_lossy().to_string();

            // Record mtime
            if let Ok(mtime) = file_mtime(&file_path) {
                files.insert(file_str.clone(), mtime);
            }

            match read_json_file(&file_path) {
                Ok(value) => {
                    let flat = flatten_table(&value, "");
                    insert_items(index, &lang, &ns, &flat, &file_str, 30);
                }
                Err(e) => {
                    errors.push(IndexError {
                        lang: lang.clone(),
                        file: file_str,
                        error: e.to_string(),
                    });
                }
            }
        }

        if has_json_file {
            languages.insert(lang);
        }
    }
}

/// Process a next-intl root: messages/{lang}/{ns}.json and messages/{lang}.json
fn process_next_intl(
    root: &Path,
    index: &mut HashMap<String, HashMap<String, ResourceItem>>,
    files: &mut HashMap<String, u64>,
    languages: &mut BTreeSet<String>,
    namespaces: &mut BTreeSet<String>,
    errors: &mut Vec<IndexError>,
) {
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();

        if path.is_dir() {
            // Subdirectory = language, files inside = namespaces
            let lang = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            let mut has_json_file = false;

            let lang_entries = match std::fs::read_dir(&path) {
                Ok(e) => e,
                Err(_) => continue,
            };

            for file_entry in lang_entries.flatten() {
                let file_path = file_entry.path();
                if file_path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                has_json_file = true;
                let ns = match file_path.file_stem().and_then(|n| n.to_str()) {
                    Some(n) => n.to_string(),
                    None => continue,
                };
                namespaces.insert(ns.clone());

                let file_str = file_path.to_string_lossy().to_string();

                if let Ok(mtime) = file_mtime(&file_path) {
                    files.insert(file_str.clone(), mtime);
                }

                match read_json_file(&file_path) {
                    Ok(value) => {
                        let flat = flatten_table(&value, "");
                        insert_items(index, &lang, &ns, &flat, &file_str, 50);
                    }
                    Err(e) => {
                        errors.push(IndexError {
                            lang: lang.clone(),
                            file: file_str,
                            error: e.to_string(),
                        });
                    }
                }
            }

            if has_json_file {
                languages.insert(lang);
            }
        } else if path.extension().and_then(|e| e.to_str()) == Some("json") {
            // Root-level {lang}.json: top-level keys are namespaces
            let lang = match path.file_stem().and_then(|n| n.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            languages.insert(lang.clone());

            let file_str = path.to_string_lossy().to_string();

            if let Ok(mtime) = file_mtime(&path) {
                files.insert(file_str.clone(), mtime);
            }

            match read_json_file(&path) {
                Ok(Value::Object(map)) => {
                    // Each top-level key is a namespace
                    for (ns, ns_value) in &map {
                        namespaces.insert(ns.clone());
                        let flat = flatten_table(ns_value, "");
                        insert_items(index, &lang, ns, &flat, &file_str, 40);
                    }
                }
                Ok(_) => {
                    errors.push(IndexError {
                        lang: lang.clone(),
                        file: file_str,
                        error: "expected top-level JSON object".to_string(),
                    });
                }
                Err(e) => {
                    errors.push(IndexError {
                        lang: lang.clone(),
                        file: file_str,
                        error: e.to_string(),
                    });
                }
            }
        }
    }
}

pub fn build_index(params: BuildIndexParams, cache: &IndexCache) -> Result<Value> {
    let cache_key = serde_json::to_string(&params.roots)?;

    let mut index: HashMap<String, HashMap<String, ResourceItem>> = HashMap::new();
    let mut files: HashMap<String, u64> = HashMap::new();
    let mut languages: BTreeSet<String> = BTreeSet::new();
    let mut namespaces: BTreeSet<String> = BTreeSet::new();
    let mut errors: Vec<IndexError> = Vec::new();

    for root in &params.roots {
        let root_path = PathBuf::from(&root.path);
        match root.kind.as_str() {
            "i18next" => {
                process_i18next(
                    &root_path,
                    &mut index,
                    &mut files,
                    &mut languages,
                    &mut namespaces,
                    &mut errors,
                );
            }
            "next-intl" => {
                process_next_intl(
                    &root_path,
                    &mut index,
                    &mut files,
                    &mut languages,
                    &mut namespaces,
                    &mut errors,
                );
            }
            _ => {
                // Unknown kind, skip
            }
        }
    }

    let result = IndexResult {
        index,
        files,
        languages: languages.into_iter().collect(),
        errors,
        namespaces: namespaces.into_iter().collect(),
    };

    cache.set(cache_key.clone(), result.clone());

    let mut value = serde_json::to_value(result)?;
    if let Some(obj) = value.as_object_mut() {
        obj.insert("cache_key".to_string(), Value::String(cache_key));
    }
    Ok(value)
}

fn remove_entries_by_file(
    index: &mut HashMap<String, HashMap<String, ResourceItem>>,
    file_path: &str,
) {
    for lang_map in index.values_mut() {
        lang_map.retain(|_, item| item.file.as_deref() != Some(file_path));
    }
    index.retain(|_, lang_map| !lang_map.is_empty());
}

fn refresh_languages_and_namespaces(result: &mut IndexResult) {
    let mut languages = BTreeSet::new();
    let mut namespaces = BTreeSet::new();

    result.index.retain(|_, lang_map| !lang_map.is_empty());

    for (lang, lang_map) in &result.index {
        if !lang_map.is_empty() {
            languages.insert(lang.clone());
        }
        for key in lang_map.keys() {
            if let Some((ns, _)) = key.split_once(':') {
                namespaces.insert(ns.to_string());
            }
        }
    }

    result.languages = languages.into_iter().collect();
    result.namespaces = namespaces.into_iter().collect();
}

pub fn apply_changes(params: ApplyChangesParams, cache: &IndexCache) -> Result<Value> {
    let cached = match cache.get(&params.cache_key) {
        Some(c) => c,
        None => {
            return Ok(serde_json::json!({
                "success": false,
                "needs_rebuild": true
            }));
        }
    };

    let mut updated = cached.clone();
    let roots: Vec<RootConfig> = match serde_json::from_str(&params.cache_key) {
        Ok(r) => r,
        Err(_) => {
            return Ok(serde_json::json!({
                "success": false,
                "needs_rebuild": true
            }));
        }
    };

    for path_str in &params.paths {
        let path = PathBuf::from(path_str);

        // Must be a .json file
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            return Ok(serde_json::json!({
                "success": false,
                "needs_rebuild": true
            }));
        }

        if path.exists() && !path.is_file() {
            return Ok(serde_json::json!({
                "success": false,
                "needs_rebuild": true
            }));
        }

        let mut matched_root_kind: Option<String> = None;
        let mut matched_components: Vec<String> = Vec::new();
        for root in &roots {
            let root_path = PathBuf::from(&root.path);
            if let Ok(relative) = path.strip_prefix(&root_path) {
                let components: Vec<String> = relative
                    .components()
                    .filter_map(|c| c.as_os_str().to_str())
                    .map(|s| s.to_string())
                    .collect();
                if !components.is_empty() {
                    matched_root_kind = Some(root.kind.clone());
                    matched_components = components;
                    break;
                }
            }
        }

        let root_kind = match matched_root_kind {
            Some(kind) => kind,
            None => {
                return Ok(serde_json::json!({
                    "success": false,
                    "needs_rebuild": true
                }));
            }
        };

        let is_deleted = !path.is_file();
        let is_next_intl_root_file = root_kind == "next-intl" && matched_components.len() == 1;
        if is_deleted || is_next_intl_root_file {
            return Ok(serde_json::json!({
                "success": false,
                "needs_rebuild": true
            }));
        }

        // Remove old entries/errors for this file regardless of change type.
        remove_entries_by_file(&mut updated.index, path_str);
        updated.files.remove(path_str);
        updated.errors.retain(|entry| entry.file != *path_str);

        // Re-read and re-parse the changed file.
        let new_value = match read_json_file(&path) {
            Ok(v) => v,
            Err(_) => {
                return Ok(serde_json::json!({
                    "success": false,
                    "needs_rebuild": true
                }));
            }
        };

        // Update mtime
        if let Ok(mtime) = file_mtime(&path) {
            updated.files.insert(path_str.clone(), mtime);
        }

        let components: Vec<&str> = matched_components.iter().map(|s| s.as_str()).collect();
        match root_kind.as_str() {
            "i18next" => {
                // Expected: {lang}/{ns}.json
                if components.len() != 2 {
                    return Ok(serde_json::json!({
                        "success": false,
                        "needs_rebuild": true
                    }));
                }
                let lang = components[0];
                let ns = Path::new(components[1])
                    .file_stem()
                    .and_then(|n| n.to_str())
                    .unwrap_or("");
                let flat = flatten_table(&new_value, "");
                insert_items(&mut updated.index, lang, ns, &flat, path_str, 30);
            }
            "next-intl" => {
                if components.len() == 2 {
                    // {lang}/{ns}.json
                    let lang = components[0];
                    let ns = Path::new(components[1])
                        .file_stem()
                        .and_then(|n| n.to_str())
                        .unwrap_or("");
                    let flat = flatten_table(&new_value, "");
                    insert_items(&mut updated.index, lang, ns, &flat, path_str, 50);
                } else if components.len() == 1 {
                    // {lang}.json root file
                    let lang = Path::new(components[0])
                        .file_stem()
                        .and_then(|n| n.to_str())
                        .unwrap_or("");
                    if let Value::Object(map) = &new_value {
                        for (ns, ns_value) in map {
                            let flat = flatten_table(ns_value, "");
                            insert_items(&mut updated.index, lang, ns, &flat, path_str, 40);
                        }
                    }
                } else {
                    return Ok(serde_json::json!({
                        "success": false,
                        "needs_rebuild": true
                    }));
                }
            }
            _ => {
                return Ok(serde_json::json!({
                    "success": false,
                    "needs_rebuild": true
                }));
            }
        }
    }

    refresh_languages_and_namespaces(&mut updated);

    // Update cache
    cache.set(params.cache_key, updated.clone());

    Ok(serde_json::json!({
        "success": true,
        "needs_rebuild": false,
        "result": updated
    }))
}
