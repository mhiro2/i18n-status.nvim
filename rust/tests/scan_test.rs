use i18n_status_core::scan;

fn extract(source: &str, lang: &str, fallback_ns: &str) -> serde_json::Value {
    let params = scan::ExtractParams {
        source: source.to_string(),
        lang: lang.to_string(),
        fallback_namespace: fallback_ns.to_string(),
        range: None,
    };
    scan::extract(params).expect("extract should succeed")
}

fn extract_with_range(
    source: &str,
    lang: &str,
    fallback_ns: &str,
    start_line: u32,
    end_line: u32,
) -> serde_json::Value {
    let params = scan::ExtractParams {
        source: source.to_string(),
        lang: lang.to_string(),
        fallback_namespace: fallback_ns.to_string(),
        range: Some(scan::Range {
            start_line,
            end_line,
        }),
    };
    scan::extract(params).expect("extract should succeed")
}

#[test]
fn simple_t_call() {
    let source = r#"
const { t } = useTranslation("common");
t("hello");
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:hello");
    assert_eq!(items[0]["namespace"], "common");
    assert_eq!(items[0]["fallback"], false);
}

#[test]
fn namespaced_key_with_colon() {
    let source = r#"
const { t } = useTranslation("common");
t("errors:not_found");
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "errors:not_found");
    assert_eq!(items[0]["namespace"], "errors");
    assert_eq!(items[0]["fallback"], false);
}

#[test]
fn use_translation_scope_detection() {
    let source = r#"
function MyComponent() {
  const { t } = useTranslation("dashboard");
  return t("title");
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "dashboard:title");
    assert_eq!(items[0]["namespace"], "dashboard");
}

#[test]
fn use_translations_next_intl_style() {
    let source = r#"
function MyComponent() {
  const t = useTranslations("settings");
  return t("theme");
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "settings:theme");
    assert_eq!(items[0]["namespace"], "settings");
}

#[test]
fn member_call_i18n_t() {
    let source = r#"
i18n.t("greeting");
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "translation:greeting");
    assert_eq!(items[0]["raw"], "greeting");
}

#[test]
fn template_literal_key() {
    let source = r#"
const { t } = useTranslation("common");
t(`welcome`);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:welcome");
}

#[test]
fn const_reference_resolution() {
    let source = r#"
const KEY = "my_key";
const { t } = useTranslation("common");
t(KEY);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:my_key");
    assert_eq!(items[0]["raw"], "my_key");
}

#[test]
fn fallback_namespace_applied_when_no_explicit_ns() {
    let source = r#"
t("orphan_key");
"#;
    let result = extract(source, "tsx", "fallback_ns");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "fallback_ns:orphan_key");
    assert_eq!(items[0]["namespace"], "fallback_ns");
    assert_eq!(items[0]["fallback"], true);
}

#[test]
fn range_filtering() {
    // Line numbers are 0-indexed in the output.
    // Line 0: (empty)
    // Line 1: t("first");
    // Line 2: t("second");
    // Line 3: t("third");
    let source = r#"
t("first");
t("second");
t("third");
"#;
    // Only extract line 2 (0-indexed)
    let result = extract_with_range(source, "tsx", "ns", 2, 2);
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["raw"], "second");
}

#[test]
fn translation_context_at_basic() {
    let source = r#"
function Page() {
  const { t } = useTranslation("home");
  return t("title");
}
"#;
    let params = scan::TranslationContextParams {
        source: source.to_string(),
        lang: "tsx".to_string(),
        row: 3,
        fallback_namespace: "translation".to_string(),
    };
    let result = scan::translation_context_at(params).expect("should succeed");
    assert_eq!(result["namespace"], "home");
    assert_eq!(result["t_func"], "t");
    assert_eq!(result["found_hook"], true);
    assert_eq!(result["has_any_hook"], true);
}

#[test]
fn translation_context_at_outside_scope() {
    let source = r#"
function Page() {
  const { t } = useTranslation("home");
  return t("title");
}
"#;
    // Row 0 is outside the function body scope
    let params = scan::TranslationContextParams {
        source: source.to_string(),
        lang: "tsx".to_string(),
        row: 0,
        fallback_namespace: "default_ns".to_string(),
    };
    let result = scan::translation_context_at(params).expect("should succeed");
    assert_eq!(result["namespace"], "default_ns");
    assert_eq!(result["found_hook"], false);
    assert_eq!(result["has_any_hook"], true);
}

#[test]
fn const_reference_resolution_inside_function_scope() {
    let source = r#"
function Page() {
  const KEY = "inner.title";
  return t(KEY);
}
"#;
    let result = extract(source, "tsx", "common");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:inner.title");
    assert_eq!(items[0]["raw"], "inner.title");
}

#[test]
fn const_shadowing_uses_nearest_scope() {
    let source = r#"
const KEY = "outer.title";
function Page() {
  const KEY = "inner.title";
  t(KEY);
}
t(KEY);
"#;
    let result = extract(source, "tsx", "common");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["key"], "common:inner.title");
    assert_eq!(items[0]["raw"], "inner.title");
    assert_eq!(items[1]["key"], "common:outer.title");
    assert_eq!(items[1]["raw"], "outer.title");
}

#[test]
fn ts_as_const_literal() {
    let source = r#"
const { t } = useTranslation("common");
t("hello" as const);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:hello");
}

#[test]
fn ts_satisfies_literal() {
    let source = r#"
const { t } = useTranslation("common");
t("hello" satisfies string);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:hello");
}

#[test]
fn ts_non_null_assertion() {
    let source = r#"
const KEY = "hello";
const { t } = useTranslation("common");
t(KEY!);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:hello");
}

#[test]
fn const_with_as_const() {
    let source = r#"
const KEY = "hello" as const;
const { t } = useTranslation("common");
t(KEY);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:hello");
}

#[test]
fn template_literal_with_const_expr() {
    let source = r#"
const prefix = "errors";
const { t } = useTranslation("common");
t(`${prefix}.not_found`);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:errors.not_found");
}

#[test]
fn template_literal_mixed() {
    let source = r#"
const a = "errors";
const b = "validation";
const { t } = useTranslation("common");
t(`${a}.${b}.required`);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:errors.validation.required");
}

#[test]
fn template_literal_with_unresolvable_expr() {
    let source = r#"
const { t } = useTranslation("common");
t(`${dynamic}.key`);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 0);
}

#[test]
fn extract_resource_preserves_source_line_locations() {
    let source = r#"{
  "login": {
    "title": "Login",
    "desc": "Description"
  },
  "plain": "OK"
}"#;
    let params = scan::ExtractResourceParams {
        source: source.to_string(),
        namespace: "common".to_string(),
        is_root: false,
        range: None,
    };

    let result = scan::extract_resource(params).expect("extract_resource should succeed");
    let items = result["items"].as_array().unwrap();

    let mut lnums = std::collections::HashMap::new();
    for item in items {
        let key = item["key"].as_str().unwrap().to_string();
        let lnum = item["lnum"].as_u64().unwrap() as u32;
        lnums.insert(key, lnum);
    }

    assert_eq!(lnums.get("common:login.title"), Some(&2));
    assert_eq!(lnums.get("common:login.desc"), Some(&3));
    assert_eq!(lnums.get("common:plain"), Some(&5));
}
