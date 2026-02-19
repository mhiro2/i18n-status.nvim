use i18n_status_core::resolve;
use std::collections::HashMap;

fn make_resource(value: &str) -> resolve::ResourceItemInput {
    resolve::ResourceItemInput {
        value: Some(value.to_string()),
        file: None,
        priority: 0,
    }
}

fn make_item(key: &str, ns: &str) -> resolve::ScanItemInput {
    let raw = key.split_once(':').map(|(_, k)| k).unwrap_or(key);
    resolve::ScanItemInput {
        key: key.to_string(),
        raw: raw.to_string(),
        namespace: ns.to_string(),
        fallback: false,
    }
}

fn compute(
    items: Vec<resolve::ScanItemInput>,
    index: HashMap<String, HashMap<String, resolve::ResourceItemInput>>,
    languages: Vec<&str>,
) -> serde_json::Value {
    let params = resolve::ComputeParams {
        items,
        primary_lang: "en".to_string(),
        languages: languages.into_iter().map(|s| s.to_string()).collect(),
        index,
        current_lang: None,
    };
    resolve::compute(params).expect("compute should succeed")
}

#[test]
fn status_synced_when_all_langs_same_value() {
    let mut index: HashMap<String, HashMap<String, resolve::ResourceItemInput>> = HashMap::new();

    let mut en = HashMap::new();
    en.insert("common:hello".to_string(), make_resource("Hello"));
    index.insert("en".to_string(), en);

    let mut ja = HashMap::new();
    ja.insert("common:hello".to_string(), make_resource("Hello"));
    index.insert("ja".to_string(), ja);

    let items = vec![make_item("common:hello", "common")];
    let result = compute(items, index, vec!["en", "ja"]);

    let resolved = result["resolved"].as_array().unwrap();
    assert_eq!(resolved.len(), 1);
    assert_eq!(resolved[0]["status"], "=");
}

#[test]
fn status_localized_when_different_value() {
    let mut index: HashMap<String, HashMap<String, resolve::ResourceItemInput>> = HashMap::new();

    let mut en = HashMap::new();
    en.insert("common:hello".to_string(), make_resource("Hello"));
    index.insert("en".to_string(), en);

    let mut ja = HashMap::new();
    ja.insert("common:hello".to_string(), make_resource("こんにちは"));
    index.insert("ja".to_string(), ja);

    let items = vec![make_item("common:hello", "common")];
    let result = compute(items, index, vec!["en", "ja"]);

    let resolved = result["resolved"].as_array().unwrap();
    assert_eq!(resolved[0]["status"], "\u{2260}"); // ≠
}

#[test]
fn status_fallback_when_lang_missing() {
    let mut index: HashMap<String, HashMap<String, resolve::ResourceItemInput>> = HashMap::new();

    let mut en = HashMap::new();
    en.insert("common:hello".to_string(), make_resource("Hello"));
    index.insert("en".to_string(), en);

    // ja has no entry for this key
    let ja: HashMap<String, resolve::ResourceItemInput> = HashMap::new();
    index.insert("ja".to_string(), ja);

    let items = vec![make_item("common:hello", "common")];
    let result = compute(items, index, vec!["en", "ja"]);

    let resolved = result["resolved"].as_array().unwrap();
    assert_eq!(resolved[0]["status"], "?");
}

#[test]
fn status_missing_primary_when_en_missing() {
    let mut index: HashMap<String, HashMap<String, resolve::ResourceItemInput>> = HashMap::new();

    // en has no entry
    let en: HashMap<String, resolve::ResourceItemInput> = HashMap::new();
    index.insert("en".to_string(), en);

    let mut ja = HashMap::new();
    ja.insert("common:hello".to_string(), make_resource("こんにちは"));
    index.insert("ja".to_string(), ja);

    let items = vec![make_item("common:hello", "common")];
    let result = compute(items, index, vec!["en", "ja"]);

    let resolved = result["resolved"].as_array().unwrap();
    assert_eq!(resolved[0]["status"], "\u{00d7}"); // ×
}

#[test]
fn status_placeholder_mismatch() {
    let mut index: HashMap<String, HashMap<String, resolve::ResourceItemInput>> = HashMap::new();

    let mut en = HashMap::new();
    en.insert(
        "common:greeting".to_string(),
        make_resource("Hello {{name}}"),
    );
    index.insert("en".to_string(), en);

    let mut ja = HashMap::new();
    // Missing the {{name}} placeholder
    ja.insert("common:greeting".to_string(), make_resource("こんにちは"));
    index.insert("ja".to_string(), ja);

    let items = vec![make_item("common:greeting", "common")];
    let result = compute(items, index, vec!["en", "ja"]);

    let resolved = result["resolved"].as_array().unwrap();
    assert_eq!(resolved[0]["status"], "!");
}

#[test]
fn status_placeholder_match_is_localized() {
    let mut index: HashMap<String, HashMap<String, resolve::ResourceItemInput>> = HashMap::new();

    let mut en = HashMap::new();
    en.insert(
        "common:greeting".to_string(),
        make_resource("Hello {{name}}"),
    );
    index.insert("en".to_string(), en);

    let mut ja = HashMap::new();
    ja.insert(
        "common:greeting".to_string(),
        make_resource("こんにちは {{name}}"),
    );
    index.insert("ja".to_string(), ja);

    let items = vec![make_item("common:greeting", "common")];
    let result = compute(items, index, vec!["en", "ja"]);

    let resolved = result["resolved"].as_array().unwrap();
    // Placeholders match and values differ, so it should be localized
    assert_eq!(resolved[0]["status"], "\u{2260}"); // ≠
}
