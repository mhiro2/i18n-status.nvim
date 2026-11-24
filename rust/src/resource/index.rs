use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use super::io::{file_mtime, read_json_file};
use crate::scan::TranslationFramework;
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
    /// Framework whose resource layout the value was read from; it decides the message syntax.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub framework: Option<TranslationFramework>,
}

/// Where a resource file sits in a supported layout.
#[derive(Debug, Clone, Copy)]
struct ResourceSource {
    /// Lower values win when several files define the same language and key.
    priority: u32,
    framework: TranslationFramework,
}

const I18NEXT_NAMESPACE_FILE: ResourceSource = ResourceSource {
    priority: 30,
    framework: TranslationFramework::I18next,
};
const NEXT_INTL_ROOT_FILE: ResourceSource = ResourceSource {
    priority: 40,
    framework: TranslationFramework::NextIntl,
};
const NEXT_INTL_NAMESPACE_FILE: ResourceSource = ResourceSource {
    priority: 50,
    framework: TranslationFramework::NextIntl,
};

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
    /// lang -> canonical keys that more than one file defines. `index` keeps only the winning
    /// entry of such a key, so an incremental update touching it cannot tell what a full build
    /// would pick.
    #[serde(skip)]
    pub contested: HashMap<String, HashSet<String>>,
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

    fn lock_entries(&self) -> MutexGuard<'_, HashMap<String, IndexResult>> {
        match self.entries.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                // A handler panicked while holding the lock. Clear the poison so
                // future locks succeed, then drop the possibly half-updated state
                // so the cache keeps serving (rebuilding as needed) instead of
                // erroring on every call until the server restarts.
                self.entries.clear_poison();
                let mut entries = poisoned.into_inner();
                entries.clear();
                entries
            }
        }
    }

    fn get(&self, key: &str) -> Option<IndexResult> {
        self.lock_entries().get(key).cloned()
    }

    fn set(&self, key: String, value: IndexResult) {
        self.lock_entries().insert(key, value);
    }
}

impl Default for IndexCache {
    fn default() -> Self {
        Self::new()
    }
}

/// Insert items into the index. Only replaces if the new priority is lower (wins). Keys that are
/// already defined by another file are recorded in `contested`.
fn insert_items(
    index: &mut HashMap<String, HashMap<String, ResourceItem>>,
    contested: &mut HashMap<String, HashSet<String>>,
    lang: &str,
    namespace: &str,
    flat: &BTreeMap<String, String>,
    file_path: &str,
    source: ResourceSource,
) {
    let lang_map = index.entry(lang.to_string()).or_default();
    for (key, value) in flat {
        let canonical_key = format!("{}:{}", namespace, key);
        let item = ResourceItem {
            value: Some(value.clone()),
            file: Some(file_path.to_string()),
            priority: source.priority,
            framework: Some(source.framework),
        };
        match lang_map.entry(canonical_key) {
            std::collections::hash_map::Entry::Vacant(e) => {
                e.insert(item);
            }
            std::collections::hash_map::Entry::Occupied(mut e) => {
                contested
                    .entry(lang.to_string())
                    .or_default()
                    .insert(e.key().clone());
                if source.priority < e.get().priority {
                    e.insert(item);
                }
            }
        }
    }
}

/// Process an i18next root: locales/{lang}/{ns}.json
fn process_i18next(
    root: &Path,
    index: &mut HashMap<String, HashMap<String, ResourceItem>>,
    contested: &mut HashMap<String, HashSet<String>>,
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
                    insert_items(
                        index,
                        contested,
                        &lang,
                        &ns,
                        &flat,
                        &file_str,
                        I18NEXT_NAMESPACE_FILE,
                    );
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
    contested: &mut HashMap<String, HashSet<String>>,
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
                        insert_items(
                            index,
                            contested,
                            &lang,
                            &ns,
                            &flat,
                            &file_str,
                            NEXT_INTL_NAMESPACE_FILE,
                        );
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
                        insert_items(
                            index,
                            contested,
                            &lang,
                            ns,
                            &flat,
                            &file_str,
                            NEXT_INTL_ROOT_FILE,
                        );
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
    let mut contested: HashMap<String, HashSet<String>> = HashMap::new();
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
                    &mut contested,
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
                    &mut contested,
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
        contested,
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

/// Whether a key `file_path` defines in the index is also defined by another file. Removing such
/// a key would drop the other file's definition, which the index no longer holds.
fn defines_contested_key(result: &IndexResult, file_path: &str) -> bool {
    result.index.iter().any(|(lang, lang_map)| {
        result.contested.get(lang).is_some_and(|keys| {
            lang_map
                .iter()
                .any(|(key, item)| item.file.as_deref() == Some(file_path) && keys.contains(key))
        })
    })
}

/// Whether another file already defines one of `flat`'s keys, checked after the changed file's
/// own entries were removed. Which definition wins then depends on the order of a full build.
fn defined_by_other_files(
    result: &IndexResult,
    lang: &str,
    namespace: &str,
    flat: &BTreeMap<String, String>,
) -> bool {
    let Some(lang_map) = result.index.get(lang) else {
        return false;
    };
    flat.keys()
        .any(|key| lang_map.contains_key(&format!("{}:{}", namespace, key)))
}

/// Add the languages and namespaces of changed files, as a full build lists them from files rather
/// than from entries, so empty files keep their language and namespace. Deleted files trigger a
/// full rebuild, so incremental updates never need to remove one.
fn extend_languages_and_namespaces(
    result: &mut IndexResult,
    changed: impl IntoIterator<Item = (String, String)>,
) {
    let mut languages: BTreeSet<String> =
        std::mem::take(&mut result.languages).into_iter().collect();
    let mut namespaces: BTreeSet<String> =
        std::mem::take(&mut result.namespaces).into_iter().collect();
    for (lang, ns) in changed {
        languages.insert(lang);
        namespaces.insert(ns);
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

    let mut changed = Vec::new();
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

        // Keys shared with other files need a full build to pick the winning definition.
        if defines_contested_key(&updated, path_str) {
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

        // Only {lang}/{ns}.json files update incrementally; next-intl root files rebuild above.
        let source = match root_kind.as_str() {
            "i18next" => I18NEXT_NAMESPACE_FILE,
            "next-intl" => NEXT_INTL_NAMESPACE_FILE,
            _ => {
                return Ok(serde_json::json!({
                    "success": false,
                    "needs_rebuild": true
                }));
            }
        };
        let [lang, file_name] = matched_components.as_slice() else {
            return Ok(serde_json::json!({
                "success": false,
                "needs_rebuild": true
            }));
        };
        let ns = Path::new(file_name)
            .file_stem()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        let flat = flatten_table(&new_value, "");
        if defined_by_other_files(&updated, lang, ns, &flat) {
            return Ok(serde_json::json!({
                "success": false,
                "needs_rebuild": true
            }));
        }
        insert_items(
            &mut updated.index,
            &mut updated.contested,
            lang,
            ns,
            &flat,
            path_str,
            source,
        );
        changed.push((lang.clone(), ns.to_string()));
    }

    updated.index.retain(|_, lang_map| !lang_map.is_empty());
    extend_languages_and_namespaces(&mut updated, changed);

    // Update cache
    cache.set(params.cache_key, updated.clone());

    Ok(serde_json::json!({
        "success": true,
        "needs_rebuild": false,
        "result": updated
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn index_cache_recovers_from_poisoned_lock() {
        let cache = IndexCache::new();
        let sample = IndexResult {
            index: HashMap::new(),
            files: HashMap::new(),
            languages: vec![],
            errors: vec![],
            namespaces: vec![],
            contested: HashMap::new(),
        };
        cache.set("k".to_string(), sample.clone());

        // Poison the lock by panicking while it is held.
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = cache.entries.lock().expect("failed to lock cache");
            panic!("poison cache lock");
        }));

        // The cache recovers: the possibly half-updated state is cleared and it
        // keeps serving requests instead of erroring until the server restarts.
        assert!(cache.get("k").is_none());
        cache.set("k2".to_string(), sample);
        assert!(cache.get("k2").is_some());
    }

    #[test]
    fn apply_changes_keeps_languages_and_namespaces_of_empty_files() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock should follow the Unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "i18n-status-index-empty-{}-{unique}",
            std::process::id()
        ));
        let write = |relative: &str, contents: &str| {
            let path = root.join(relative);
            std::fs::create_dir_all(path.parent().expect("file should have a parent"))
                .expect("directory should be created");
            std::fs::write(&path, contents).expect("file should be written");
            path.to_string_lossy().to_string()
        };
        let en_common = write("en/common.json", r#"{"hello":"Hello"}"#);
        write("en/admin.json", "{}");
        write("ja/common.json", "{}");

        let cache = IndexCache::new();
        let roots = vec![RootConfig {
            kind: "i18next".to_string(),
            path: root.to_string_lossy().to_string(),
        }];
        let built = build_index(BuildIndexParams { roots }, &cache).expect("index should build");
        let cache_key = built["cache_key"]
            .as_str()
            .expect("build should report its cache key")
            .to_string();
        assert_eq!(built["languages"], serde_json::json!(["en", "ja"]));
        assert_eq!(built["namespaces"], serde_json::json!(["admin", "common"]));

        write("en/common.json", r#"{"hello":"Hi"}"#);
        let ko_common = write("ko/common.json", "{}");
        let applied = apply_changes(
            ApplyChangesParams {
                cache_key,
                paths: vec![en_common, ko_common],
            },
            &cache,
        )
        .expect("changes should apply");
        std::fs::remove_dir_all(&root).expect("temporary root should be removed");

        assert_eq!(applied["success"], serde_json::json!(true));
        let result = &applied["result"];
        assert_eq!(result["languages"], serde_json::json!(["en", "ja", "ko"]));
        assert_eq!(result["namespaces"], serde_json::json!(["admin", "common"]));
        assert_eq!(result["index"]["en"]["common:hello"]["value"], "Hi");
    }

    /// Two i18next roots, as in a monorepo whose packages both ship `en/common.json`.
    struct TwoRoots {
        base: PathBuf,
        roots: Vec<RootConfig>,
    }

    impl TwoRoots {
        fn new(name: &str) -> Self {
            let unique = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock should follow the Unix epoch")
                .as_nanos();
            let base = std::env::temp_dir().join(format!(
                "i18n-status-index-{name}-{}-{unique}",
                std::process::id()
            ));
            let roots = ["pkg-a", "pkg-b"]
                .iter()
                .map(|pkg| RootConfig {
                    kind: "i18next".to_string(),
                    path: base.join(pkg).to_string_lossy().to_string(),
                })
                .collect();
            Self { base, roots }
        }

        fn write(&self, pkg: &str, contents: &str) -> String {
            let path = self.base.join(pkg).join("en/common.json");
            std::fs::create_dir_all(path.parent().expect("file should have a parent"))
                .expect("directory should be created");
            std::fs::write(&path, contents).expect("file should be written");
            path.to_string_lossy().to_string()
        }

        fn build(&self, cache: &IndexCache) -> Value {
            build_index(
                BuildIndexParams {
                    roots: self.roots.clone(),
                },
                cache,
            )
            .expect("index should build")
        }
    }

    impl Drop for TwoRoots {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.base);
        }
    }

    fn apply(cache: &IndexCache, built: &Value, path: String) -> Value {
        let cache_key = built["cache_key"]
            .as_str()
            .expect("build should report its cache key")
            .to_string();
        apply_changes(
            ApplyChangesParams {
                cache_key,
                paths: vec![path],
            },
            cache,
        )
        .expect("changes should apply")
    }

    #[test]
    fn apply_changes_rebuilds_when_removing_key_another_file_defines() {
        let roots = TwoRoots::new("remove-shared");
        let a = roots.write("pkg-a", r#"{"title":"A"}"#);
        roots.write("pkg-b", r#"{"title":"B"}"#);
        let cache = IndexCache::new();
        let built = roots.build(&cache);
        assert_eq!(built["index"]["en"]["common:title"]["value"], "A");

        // A full build falls back to the other root's definition, which the index does not hold.
        roots.write("pkg-a", "{}");
        let applied = apply(&cache, &built, a);
        assert_eq!(applied["needs_rebuild"], serde_json::json!(true));
        let rebuilt = roots.build(&IndexCache::new());
        assert_eq!(rebuilt["index"]["en"]["common:title"]["value"], "B");
    }

    #[test]
    fn apply_changes_rebuilds_when_adding_key_another_file_defines() {
        let roots = TwoRoots::new("add-shared");
        let a = roots.write("pkg-a", r#"{"other":"x"}"#);
        roots.write("pkg-b", r#"{"title":"B"}"#);
        let cache = IndexCache::new();
        let built = roots.build(&cache);
        assert_eq!(built["index"]["en"]["common:title"]["value"], "B");

        // The first root wins ties in a full build, so its new definition must replace the other.
        roots.write("pkg-a", r#"{"other":"x","title":"A"}"#);
        let applied = apply(&cache, &built, a);
        assert_eq!(applied["needs_rebuild"], serde_json::json!(true));
        let rebuilt = roots.build(&IndexCache::new());
        assert_eq!(rebuilt["index"]["en"]["common:title"]["value"], "A");
    }

    #[test]
    fn apply_changes_stays_incremental_when_losing_file_removes_shared_key() {
        let roots = TwoRoots::new("remove-losing");
        roots.write("pkg-a", r#"{"title":"A"}"#);
        let b = roots.write("pkg-b", r#"{"title":"B"}"#);
        let cache = IndexCache::new();
        let built = roots.build(&cache);

        // The winning definition is unaffected, so the incremental result matches a full build.
        roots.write("pkg-b", "{}");
        let applied = apply(&cache, &built, b);
        assert_eq!(applied["success"], serde_json::json!(true));
        let rebuilt = roots.build(&IndexCache::new());
        assert_eq!(
            applied["result"]["index"]["en"]["common:title"],
            rebuilt["index"]["en"]["common:title"]
        );
    }

    #[test]
    fn apply_changes_stays_incremental_for_keys_no_other_file_defines() {
        let roots = TwoRoots::new("disjoint");
        let a = roots.write("pkg-a", r#"{"title":"A"}"#);
        roots.write("pkg-b", r#"{"other":"B"}"#);
        let cache = IndexCache::new();
        let built = roots.build(&cache);

        roots.write("pkg-a", r#"{"heading":"A"}"#);
        let applied = apply(&cache, &built, a);
        assert_eq!(applied["success"], serde_json::json!(true));
        let index = &applied["result"]["index"]["en"];
        assert!(index["common:title"].is_null());
        assert_eq!(index["common:heading"]["value"], "A");
        assert_eq!(index["common:other"]["value"], "B");
    }
}
