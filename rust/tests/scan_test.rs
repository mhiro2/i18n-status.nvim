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
fn get_translations_server_style() {
    let source = r#"
async function loadMessages() {
  const t = await getTranslations("dashboard");
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
fn template_literal_keys_use_cooked_semantic_values() {
    let result = extract(r#"t(`rename.\u0074itle`);"#, "tsx", "common");

    let items = result["items"]
        .as_array()
        .expect("items should be an array");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:rename.title");
    assert_eq!(items[0]["raw"], "rename.title");
    assert_eq!(items[0]["refactorable"], true);
}

#[test]
fn template_literal_keys_reject_non_unicode_cooked_values() {
    let result = extract(r#"t(`prefix\uD800suffix`);"#, "tsx", "common");
    let items = result["items"]
        .as_array()
        .expect("items should be an array");

    assert!(items.is_empty());
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
    assert_eq!(items[0]["refactorable"], false);
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
        col: None,
        callee: None,
        member_call: false,
        fallback_namespace: "translation".to_string(),
    };
    let result = scan::translation_context_at(params).expect("should succeed");
    assert_eq!(result["namespace"], "home");
    assert_eq!(result["t_func"], "t");
    assert!(result["binding_id"].as_str().is_some());
    assert_eq!(result["hook"], "useTranslation");
    assert_eq!(result["framework"], "i18next");
    assert_eq!(result["source_key_policy"], "canonical");
    assert_eq!(result["namespace_resolution"], "static");
    assert_eq!(result["found_hook"], true);
    assert_eq!(result["has_any_hook"], true);
}

#[test]
fn next_intl_context_returns_relative_source_key_metadata() {
    let source = r#"
function Page() {
  const t = useTranslations("Home");
  return <p>Hello</p>;
}
"#;
    let result = scan::translation_context_at(scan::TranslationContextParams {
        source: source.to_string(),
        lang: "tsx".to_string(),
        row: 3,
        col: Some(12),
        callee: Some("t".to_string()),
        member_call: false,
        fallback_namespace: "translation".to_string(),
    })
    .expect("context should resolve");

    assert_eq!(result["namespace"], "Home");
    assert_eq!(result["t_func"], "t");
    assert!(result["binding_id"].as_str().is_some());
    assert_eq!(result["hook"], "useTranslations");
    assert_eq!(result["framework"], "next_intl");
    assert_eq!(result["source_key_policy"], "namespace_relative");
    assert_eq!(result["namespace_resolution"], "static");
    assert_eq!(result["extract_safe"], true);
}

#[test]
fn use_translation_options_report_extract_safety() {
    let cases = [
        ("no options", r#"useTranslation("common")"#, true),
        (
            "unrelated literal options",
            r#"useTranslation("common", { lng: "en" })"#,
            true,
        ),
        (
            "identifier keyPrefix property",
            r#"useTranslation("common", { keyPrefix: "account" })"#,
            false,
        ),
        (
            "keyPrefix shorthand",
            r#"useTranslation("common", { keyPrefix })"#,
            false,
        ),
        (
            "string keyPrefix property",
            r#"useTranslation("common", { "keyPrefix": "account" })"#,
            false,
        ),
        (
            "computed keyPrefix property",
            r#"useTranslation("common", { ["keyPrefix"]: "account" })"#,
            false,
        ),
        (
            "spread options",
            r#"useTranslation("common", { ...options })"#,
            false,
        ),
        (
            "dynamic options",
            r#"useTranslation("common", options)"#,
            false,
        ),
    ];

    for (label, hook_call, expected) in cases {
        let source = format!(
            "function Page(options, keyPrefix) {{\n  const {{ t }} = {hook_call};\n  return <p>Hello</p>;\n}}"
        );
        let result = scan::translation_context_at(scan::TranslationContextParams {
            source,
            lang: "tsx".to_string(),
            row: 2,
            col: Some(12),
            callee: Some("t".to_string()),
            member_call: false,
            fallback_namespace: "translation".to_string(),
        })
        .unwrap_or_else(|error| panic!("{label}: context should resolve: {error}"));

        assert_eq!(result["found_hook"], true, "{label}");
        assert_eq!(result["extract_safe"], expected, "{label}");
    }
}

#[test]
fn next_intl_contexts_are_extract_safe() {
    let cases = [
        (
            "useTranslations",
            "function Page() {",
            r#"const t = useTranslations("Home");"#,
        ),
        (
            "getTranslations",
            "async function Page() {",
            r#"const t = await getTranslations("Home");"#,
        ),
    ];

    for (label, function_header, binding) in cases {
        let source = format!("{function_header}\n  {binding}\n  return <p>Hello</p>;\n}}");
        let result = scan::translation_context_at(scan::TranslationContextParams {
            source,
            lang: "tsx".to_string(),
            row: 2,
            col: Some(12),
            callee: Some("t".to_string()),
            member_call: false,
            fallback_namespace: "translation".to_string(),
        })
        .unwrap_or_else(|error| panic!("{label}: context should resolve: {error}"));

        assert_eq!(result["found_hook"], true, "{label}");
        assert_eq!(result["framework"], "next_intl", "{label}");
        assert_eq!(result["extract_safe"], true, "{label}");
    }
}

#[test]
fn translation_context_distinguishes_absent_and_dynamic_namespaces() {
    let absent_source = r#"
function Page() {
  const { t } = useTranslation();
  return <p>Hello</p>;
}
"#;
    let absent = scan::translation_context_at(scan::TranslationContextParams {
        source: absent_source.to_string(),
        lang: "tsx".to_string(),
        row: 3,
        col: Some(12),
        callee: Some("t".to_string()),
        member_call: false,
        fallback_namespace: "translation".to_string(),
    })
    .expect("absent namespace should resolve to fallback");
    assert_eq!(absent["namespace_resolution"], "absent");
    assert_eq!(absent["namespace"], "translation");

    let dynamic_source = r#"
function Page(namespace) {
  const { t } = useTranslation(namespace);
  return <p>Hello</p>;
}
"#;
    let dynamic = scan::translation_context_at(scan::TranslationContextParams {
        source: dynamic_source.to_string(),
        lang: "tsx".to_string(),
        row: 3,
        col: Some(12),
        callee: Some("t".to_string()),
        member_call: false,
        fallback_namespace: "translation".to_string(),
    })
    .expect("dynamic namespace should be reported");
    assert_eq!(dynamic["namespace_resolution"], "dynamic");
    assert_eq!(dynamic["namespace"], "translation");
}

#[test]
fn get_translations_requires_await_through_typescript_wrappers() {
    let unawaited_source = r#"
async function Page() {
  const t = (getTranslations("Home") as unknown) satisfies Translator;
  return <p>Hello</p>;
}
"#;
    let unawaited = scan::translation_context_at(scan::TranslationContextParams {
        source: unawaited_source.to_string(),
        lang: "tsx".to_string(),
        row: 3,
        col: Some(12),
        callee: Some("t".to_string()),
        member_call: false,
        fallback_namespace: "translation".to_string(),
    })
    .expect("context request should succeed");
    assert!(unawaited["t_func"].is_null());
    assert!(unawaited["binding_id"].is_null());
    assert_eq!(unawaited["found_hook"], false);

    let awaited_source = r#"
async function Page() {
  const t = (await (getTranslations("Home") as unknown)) as Translator;
  return <p>Hello</p>;
}
"#;
    let awaited = scan::translation_context_at(scan::TranslationContextParams {
        source: awaited_source.to_string(),
        lang: "tsx".to_string(),
        row: 3,
        col: Some(12),
        callee: Some("t".to_string()),
        member_call: false,
        fallback_namespace: "translation".to_string(),
    })
    .expect("context request should succeed");
    assert_eq!(awaited["t_func"], "t");
    assert!(awaited["binding_id"].as_str().is_some());
    assert_eq!(awaited["hook"], "getTranslations");
    assert_eq!(awaited["source_key_policy"], "namespace_relative");
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
        col: None,
        callee: None,
        member_call: false,
        fallback_namespace: "default_ns".to_string(),
    };
    let result = scan::translation_context_at(params).expect("should succeed");
    assert_eq!(result["namespace"], "default_ns");
    assert!(result["t_func"].is_null());
    assert!(result["binding_id"].is_null());
    assert_eq!(result["found_hook"], false);
    assert_eq!(result["has_any_hook"], true);
}

#[test]
fn translation_context_uses_requested_symbol_and_rejects_ambiguity() {
    let source = r#"
function Page() {
  const { t: commonT } = useTranslation("common");
  const { t: adminT } = useTranslation("admin");
  return <p>Hello</p>;
}
"#;
    let ambiguous = scan::translation_context_at(scan::TranslationContextParams {
        source: source.to_string(),
        lang: "tsx".to_string(),
        row: 4,
        col: None,
        callee: None,
        member_call: false,
        fallback_namespace: "translation".to_string(),
    })
    .expect("context query should succeed");
    assert_eq!(ambiguous["namespace"], "translation");
    assert_eq!(ambiguous["found_hook"], false);
    assert_eq!(ambiguous["ambiguous"], true);

    let selected = scan::translation_context_at(scan::TranslationContextParams {
        source: source.to_string(),
        lang: "tsx".to_string(),
        row: 4,
        col: None,
        callee: Some("adminT".to_string()),
        member_call: false,
        fallback_namespace: "translation".to_string(),
    })
    .expect("context query should succeed");
    assert_eq!(selected["namespace"], "admin");
    assert_eq!(selected["t_func"], "adminT");
    assert_eq!(selected["found_hook"], true);
    assert_eq!(selected["ambiguous"], false);
}

#[test]
fn translation_context_binding_id_identifies_the_resolved_declaration() {
    let source = r#"
const { t } = useTranslation("outer");
function Page() {
  const before = <p>Before</p>;
  {
    const { t } = useTranslation("inner");
    const inside = <p>Inside</p>;
  }
  return <p>After</p>;
}
"#;
    let context_at = |row| {
        scan::translation_context_at(scan::TranslationContextParams {
            source: source.to_string(),
            lang: "tsx".to_string(),
            row,
            col: Some(12),
            callee: Some("t".to_string()),
            member_call: false,
            fallback_namespace: "translation".to_string(),
        })
        .expect("context should resolve")
    };

    let before = context_at(3);
    let inside = context_at(6);
    let after = context_at(8);
    assert_eq!(before["namespace"], "outer");
    assert_eq!(inside["namespace"], "inner");
    assert_eq!(after["namespace"], "outer");
    assert_eq!(before["binding_id"], after["binding_id"]);
    assert_ne!(before["binding_id"], inside["binding_id"]);
}

#[test]
fn translation_context_does_not_borrow_hook_namespace_for_member_call() {
    let source = r#"
function Page() {
  const { t } = useTranslation("home");
  return i18n.t("title");
}
"#;
    let result = scan::translation_context_at(scan::TranslationContextParams {
        source: source.to_string(),
        lang: "tsx".to_string(),
        row: 3,
        col: None,
        callee: Some("t".to_string()),
        member_call: true,
        fallback_namespace: "translation".to_string(),
    })
    .expect("context query should succeed");
    assert_eq!(result["namespace"], "translation");
    assert_eq!(result["found_hook"], false);
}

#[test]
fn translation_context_respects_non_translator_shadowing() {
    let source = r#"
const { t } = useTranslation("outer");
async function Page() {
  const t = getTranslations("not-awaited");
  return t("ignored");
}
"#;
    let call_col = source.lines().nth(4).unwrap().find("t(").unwrap() as u32;
    let result = scan::translation_context_at(scan::TranslationContextParams {
        source: source.to_string(),
        lang: "tsx".to_string(),
        row: 4,
        col: Some(call_col),
        callee: Some("t".to_string()),
        member_call: false,
        fallback_namespace: "translation".to_string(),
    })
    .expect("context query should succeed");
    assert_eq!(result["namespace"], "translation");
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
    assert_eq!(items[0]["refactorable"], false);
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
fn conditional_both_branches() {
    let source = r#"
const { t } = useTranslation("common");
t(isError ? "error.title" : "success.title");
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["key"], "common:error.title");
    assert_eq!(items[1]["key"], "common:success.title");
}

#[test]
fn nested_conditional() {
    let source = r#"
const { t } = useTranslation("common");
t(a ? "x" : b ? "y" : "z");
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 3);
    assert_eq!(items[0]["key"], "common:x");
    assert_eq!(items[1]["key"], "common:y");
    assert_eq!(items[2]["key"], "common:z");
}

#[test]
fn conditional_one_branch_unresolvable() {
    let source = r#"
const { t } = useTranslation("common");
t(cond ? dynamicVar : "fallback");
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:fallback");
}

#[test]
fn conditional_inside_concatenation() {
    let source = r#"
const { t } = useTranslation("common");
t("errors." + (cond ? "a" : "b"));
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["key"], "common:errors.a");
    assert_eq!(items[1]["key"], "common:errors.b");
}

#[test]
fn conditional_inside_template_literal() {
    let source = r#"
const { t } = useTranslation("common");
t(`${cond ? "a" : "b"}.title`);
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["key"], "common:a.title");
    assert_eq!(items[1]["key"], "common:b.title");
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

#[test]
fn extract_root_resource_uses_top_level_namespace() {
    let source = r#"{
  "common": {
    "login": {
      "title": "Login"
    }
  },
  "admin": {
    "save": "Save"
  }
}"#;
    let params = scan::ExtractResourceParams {
        source: source.to_string(),
        namespace: "ignored".to_string(),
        is_root: true,
        range: None,
    };

    let result = scan::extract_resource(params).expect("extract_resource should succeed");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["key"], "common:login.title");
    assert_eq!(items[0]["namespace"], "common");
    assert_eq!(items[1]["key"], "admin:save");
    assert_eq!(items[1]["namespace"], "admin");
}

#[test]
fn source_ranges_use_neovim_byte_columns() {
    let source = "\tconst 前置き😀 = \"値\"; t(\"title\");";
    let result = extract(source, "typescript", "common");
    let items = result["items"].as_array().unwrap();
    let expected_col = source.find("\"title\"").unwrap() as u64;

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["lnum"], 0);
    assert_eq!(items[0]["col"], expected_col);
    assert_eq!(items[0]["end_lnum"], 0);
    assert_eq!(items[0]["end_col"], expected_col + 7);
    assert_eq!(items[0]["refactorable"], true);
}

#[test]
fn computed_references_keep_multiline_ranges_but_refuse_refactoring() {
    let source = r#"t(
  enabled
    ? "first"
    : "second"
);"#;
    let result = extract(source, "typescript", "common");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 2);
    for item in items {
        assert_eq!(item["lnum"], 1);
        assert_eq!(item["end_lnum"], 3);
        assert_eq!(item["refactorable"], false);
    }
}

#[test]
fn translator_aliases_keep_their_symbol_bound_namespaces() {
    let source = r#"
function Page() {
  const { t: commonT } = useTranslation("common");
  const { t: adminT } = useTranslation("admin");
  return [commonT("title"), adminT("save")];
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["key"], "common:title");
    assert_eq!(items[1]["key"], "admin:save");
}

#[test]
fn nested_translator_shadow_uses_the_innermost_symbol() {
    let source = r#"
function Page() {
  const { t } = useTranslation("outer");
  const before = t("before");
  function Dialog() {
    const { t } = useTranslation("inner");
    return t("title");
  }
  return [before, t("after"), Dialog];
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 3);
    assert_eq!(items[0]["key"], "outer:before");
    assert_eq!(items[1]["key"], "inner:title");
    assert_eq!(items[2]["key"], "outer:after");
}

#[test]
fn ordinary_lexical_bindings_shadow_translation_symbols() {
    let source = r#"
function Page() {
  const { t } = useTranslation("outer");
  function ParameterShadow(t) {
    return t("parameter");
  }
  try {
    throw new Error("failure");
  } catch (t) {
    t("catch");
  }
  {
    const t = makeFormatter();
    t("local");
  }
  return t("visible");
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "outer:visible");
}

#[test]
fn var_binding_shadows_a_translator_across_its_function_scope() {
    let source = r#"
function Page() {
  const { t } = useTranslation("outer");
  function Nested() {
    t("before");
    if (enabled) {
      var t = makeFormatter();
    }
    t("after");
  }
  return [t("visible"), Nested];
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "outer:visible");
}

#[test]
fn translator_reassignment_stops_later_calls_from_using_the_old_namespace() {
    let source = r#"
function Page() {
  let { t } = useTranslation("outer");
  t("before");
  t = makeFormatter();
  t("after");
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "outer:before");
}

#[test]
fn assignment_before_an_inner_declaration_does_not_invalidate_the_outer_translator() {
    let source = r#"
function Page() {
  let { t } = useTranslation("outer");
  {
    t = makeFormatter();
    let t = makeFormatter();
  }
  return t("visible");
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "outer:visible");
}

#[test]
fn loop_assignment_targets_invalidate_translation_symbols() {
    let source = r#"
let { t } = useTranslation("outer");
for (t of formatters) { t("for-of"); }
let { t: second } = useTranslation("second");
for (second in formatters) { second("for-in"); }
"#;
    let result = extract(source, "tsx", "translation");

    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn destructuring_assignments_invalidate_translation_symbols() {
    let source = r#"
let { t } = useTranslation("outer");
({ t } = formatter);
t("object");
let { t: second } = useTranslation("second");
[second] = formatters;
second("array");
"#;
    let result = extract(source, "tsx", "translation");

    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn using_and_import_equals_bindings_do_not_fall_back_to_bare_t() {
    let source = r#"
import t = require("./formatter");
t("import-equals");
{
  using t = makeFormatter();
  t("using");
}
"#;
    let result = extract(source, "typescript", "translation");

    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn named_class_expression_binding_shadows_outer_translator() {
    let source = r#"
const { t } = useTranslation("outer");
const Formatter = class t { method() { return t("class-name"); } };
"#;
    let result = extract(source, "typescript", "translation");

    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn update_expressions_invalidate_translation_symbols() {
    let source = r#"
let { t } = useTranslation("outer");
t++;
t("after-update");
"#;
    let result = extract(source, "tsx", "translation");

    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn enum_and_namespace_bindings_shadow_outer_translators() {
    let source = r#"
const { t } = useTranslation("outer");
{ enum t { A } t("enum"); }
{ namespace t { export const A = 1; } t("namespace"); }
"#;
    let result = extract(source, "typescript", "translation");

    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn namespace_bindings_do_not_leak_into_outer_scopes() {
    let source = r#"
const { t } = useTranslation("outer");
namespace N {
  const t = makeFormatter();
  t("inside");
}
t("outside");
"#;
    let result = extract(source, "typescript", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "outer:outside");
}

#[test]
fn enum_initializers_can_use_outer_translators() {
    let source = r#"
const { t } = useTranslation("outer");
enum E { A = t("inside") }
"#;
    let result = extract(source, "typescript", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "outer:inside");
}

#[test]
fn translator_binding_is_not_callable_before_its_declaration() {
    let source = r#"
function Page() {
  const before = t("before"); const { t } = useTranslation("common");
  return t("after");
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "common:after");
}

#[test]
fn mixed_framework_aliases_resolve_independently() {
    let source = r#"
async function Page() {
  const { t: reactT } = useTranslation("react");
  const intlT = useTranslations("client");
  const serverT = await getTranslations("server");
  const promiseT = getTranslations("invalid");
  return [reactT("one"), intlT("two"), serverT("three"), promiseT("ignored")];
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 3);
    assert_eq!(items[0]["key"], "react:one");
    assert_eq!(items[1]["key"], "client:two");
    assert_eq!(items[2]["key"], "server:three");
}

#[test]
fn hook_aliases_resolve_by_import_identity() {
    let source = r#"
import { useTranslation as useI18n } from "react-i18next";
function Page() {
  const { t } = useI18n("auth");
  return t("title");
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "auth:title");
}

#[test]
fn commonjs_hook_aliases_resolve_by_trusted_require_identity() {
    let cases = [
        (
            r#"const { useTranslation } = require("react-i18next");"#,
            "useTranslation",
        ),
        (
            r#"const { useTranslation: useI18n } = require('react-i18next');"#,
            "useI18n",
        ),
        (
            r#"const useI18n = require("react-i18next").useTranslation;"#,
            "useI18n",
        ),
    ];

    for (binding, hook) in cases {
        let source = format!(
            r#"{binding}
function Page() {{
  const {{ t }} = {hook}("auth");
  return t("title");
}}"#
        );
        let result = extract(&source, "tsx", "translation");
        let items = result["items"].as_array().unwrap();

        assert_eq!(items.len(), 1, "{binding}");
        assert_eq!(items[0]["key"], "auth:title", "{binding}");
    }
}

#[test]
fn commonjs_hooks_reject_untrusted_or_shadowed_require_calls() {
    let cases = [
        r#"
const { useTranslation } = require("formatters");
const { t } = useTranslation("wrong");
t("ignored");
"#,
        r#"
function Page(require) {
  const { useTranslation } = require("react-i18next");
  const { t } = useTranslation("wrong");
  return t("ignored");
}
"#,
        r#"
function Page() {
  const { useTranslation } = require("react-i18next");
  var require = makeRequire();
  const { t } = useTranslation("wrong");
  return t("ignored");
}
"#,
        r#"
const packageName = "react-i18next";
const { useTranslation } = require(packageName);
const { t } = useTranslation("wrong");
t("ignored");
"#,
    ];

    for source in cases {
        let result = extract(source, "tsx", "translation");
        assert!(result["items"].as_array().unwrap().is_empty(), "{source}");
    }
}

#[test]
fn awaited_hook_detection_unwraps_typescript_assertions() {
    let source = r#"
async function Page() {
  const t = <Translator>(await getTranslations("server"));
  return t("title");
}
"#;
    let result = extract(source, "typescript", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "server:title");
}

#[test]
fn shadowed_or_untrusted_hook_names_do_not_create_translators() {
    let source = r#"
import { useTranslation as useFormatter } from "formatters";
function ParameterShadow(useTranslation) {
  const { t: first } = useTranslation("wrong");
  return first("ignored");
}
function UnknownImport() {
  const { t: second } = useFormatter("wrong");
  return second("ignored");
}
"#;
    let result = extract(source, "tsx", "translation");
    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn jsx_callback_parameters_shadow_outer_translators() {
    let source = r#"
function Page() {
  const { t } = useTranslation("outer");
  return <List render={(t) => t("ignored")} footer={t("visible")} />;
}
"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "outer:visible");
}

#[test]
fn default_parameter_expressions_collect_nested_symbol_scopes() {
    let source = r#"
const { t } = useTranslation("outer");
function Page(callback = (t) => t("ignored")) {
  return callback;
}
"#;
    let result = extract(source, "tsx", "translation");
    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn constructor_parameters_shadow_outer_translators() {
    let source = r#"
const { t } = useTranslation("outer");
class Regular { constructor(t) { t("ignored"); } }
class ParameterProperty { constructor(private t: Formatter) { t("ignored"); } }
"#;
    let result = extract(source, "tsx", "translation");
    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn object_accessors_and_static_blocks_keep_callable_scopes() {
    let source = r#"
const { t } = useTranslation("outer");
const object = {
  set value(t) { t("setter"); },
  get value() { var t = makeFormatter(); return t("getter"); }
};
class Example { static { var t = makeFormatter(); t("static"); } }
"#;
    let result = extract(source, "tsx", "translation");
    assert!(result["items"].as_array().unwrap().is_empty());
}

#[test]
fn scope_end_is_exclusive_for_an_adjacent_outer_call() {
    let source = r#"const { t } = useTranslation("outer"); function Inner() { const { t } = useTranslation("inner"); }t("after");"#;
    let result = extract(source, "tsx", "translation");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["key"], "outer:after");
}

#[test]
fn resource_ranges_also_use_byte_columns() {
    let source = r#"{"日本語":"value"}"#;
    let result = scan::extract_resource(scan::ExtractResourceParams {
        source: source.to_string(),
        namespace: "common".to_string(),
        is_root: false,
        range: None,
    })
    .expect("extract_resource should succeed");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["col"], 1);
    assert_eq!(items[0]["end_lnum"], 0);
    assert_eq!(items[0]["end_col"], 12);
    assert_eq!(items[0]["refactorable"], false);
}
