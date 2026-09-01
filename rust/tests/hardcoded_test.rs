use i18n_status_core::hardcoded;
use i18n_status_core::scan::Range;

fn extract(source: &str, lang: &str) -> serde_json::Value {
    let params = hardcoded::ExtractParams {
        source: source.to_string(),
        lang: lang.to_string(),
        range: None,
        min_length: 2,
        exclude_components: vec!["Trans".to_string(), "Translation".to_string()],
    };
    hardcoded::extract(params).expect("extract should succeed")
}

fn extract_with_min_length(source: &str, min_length: usize) -> serde_json::Value {
    let params = hardcoded::ExtractParams {
        source: source.to_string(),
        lang: "tsx".to_string(),
        range: None,
        min_length,
        exclude_components: vec!["Trans".to_string()],
    };
    hardcoded::extract(params).expect("extract should succeed")
}

fn extract_with_range(source: &str, start_line: u32, end_line: u32) -> serde_json::Value {
    let params = hardcoded::ExtractParams {
        source: source.to_string(),
        lang: "tsx".to_string(),
        range: Some(Range {
            start_line,
            end_line,
        }),
        min_length: 2,
        exclude_components: vec!["Trans".to_string()],
    };
    hardcoded::extract(params).expect("extract should succeed")
}

#[test]
fn detects_jsx_text() {
    let source = r#"const App = () => <div>Hello World</div>;"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["text"], "Hello World");
    assert_eq!(items[0]["source_text"], "Hello World");
    assert_eq!(items[0]["kind"], "jsx_text");
    assert_eq!(items[0]["replacement_context"], "jsx_child");
}

#[test]
fn preserves_meaningful_spaces_at_jsx_element_boundaries() {
    let source = r#"const App = () => <p>Hello <strong>dear</strong> friend</p>;"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();
    let texts: Vec<&str> = items
        .iter()
        .map(|item| item["text"].as_str().unwrap())
        .collect();

    assert_eq!(texts, vec!["Hello ", "dear", " friend"]);
}

#[test]
fn cleans_multiline_jsx_indentation_like_react() {
    let source = r#"const App = () => (
  <p>
    Hello
    world
  </p>
);"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["text"], "Hello world");
    assert_eq!(items[0]["source_text"], "\n    Hello\n    world\n  ");
}

#[test]
fn reports_neovim_byte_columns_after_multibyte_text() {
    let source = r#"const App = () => <p>日本語<span>Hello world</span></p>;"#;
    let result = extract(source, "tsx");
    let item = result["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["text"] == "Hello world")
        .expect("nested text should be detected");

    let expected_start = source.find("Hello world").unwrap() as u64;
    assert_eq!(item["col"].as_u64(), Some(expected_start));
    assert_eq!(item["end_col"].as_u64(), Some(expected_start + 11));
}

#[test]
fn detects_jsx_literal() {
    let source = r#"const App = () => <div>{"Hello"}</div>;"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["text"], "Hello");
    assert_eq!(items[0]["source_text"], r#""Hello""#);
    assert_eq!(items[0]["kind"], "jsx_literal");
    assert_eq!(items[0]["replacement_context"], "jsx_expression");
}

#[test]
fn preserves_raw_literal_but_returns_semantic_text() {
    let source = r#"const App = () => <div>{"Hello\nworld"}</div>;"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["text"], "Hello\nworld");
    assert_eq!(items[0]["source_text"], r#""Hello\nworld""#);
    assert_eq!(items[0]["replacement_context"], "jsx_expression");
}

#[test]
fn uses_cooked_template_literal_text() {
    let source = r#"const App = () => <div>{`Hello\u0020world`}</div>;"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["text"], "Hello world");
    assert_eq!(items[0]["source_text"], r#"`Hello\u0020world`"#);
    assert_eq!(items[0]["replacement_context"], "jsx_expression");
}

#[test]
fn reports_neovim_byte_columns_after_multibyte_source() {
    let source = r#"const prefix = "あ😀"; const App = () => <div>日本語</div>;"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();
    let start = source.find("日本語").unwrap() as u64;

    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["lnum"], 0);
    assert_eq!(items[0]["col"], start);
    assert_eq!(items[0]["end_lnum"], 0);
    assert_eq!(items[0]["end_col"], start + "日本語".len() as u64);
}

#[test]
fn excluded_inside_trans_component() {
    let source = r#"const App = () => <Trans>Hello World</Trans>;"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 0, "text inside <Trans> should be excluded");
}

#[test]
fn excluded_inside_t_call() {
    // A string literal that is an argument to t() should not be flagged as hardcoded.
    // The hardcoded detector only looks at JSX children, so we put it in a JSX expression
    // container that uses t().
    let source = r#"const App = () => <div>{t("hello")}</div>;"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();
    // t("hello") is a call expression, not a string literal in JSX context,
    // so it should not be detected as hardcoded
    assert_eq!(items.len(), 0);
}

#[test]
fn min_length_filtering() {
    let source = r#"const App = () => <div>Hi</div>;"#;

    // min_length=2 should include "Hi" (length 2)
    let result = extract_with_min_length(source, 2);
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);

    // min_length=5 should exclude "Hi"
    let result = extract_with_min_length(source, 5);
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 0);
}

#[test]
fn range_filtering() {
    // Line 0: function App() {
    // Line 1:   return (
    // Line 2:     <div>
    // Line 3:       <p>First</p>
    // Line 4:       <p>Second</p>
    // Line 5:     </div>
    // Line 6:   );
    // Line 7: }
    let source = r#"function App() {
  return (
    <div>
      <p>First</p>
      <p>Second</p>
    </div>
  );
}"#;
    // Only extract around line 3
    let result = extract_with_range(source, 3, 3);
    let items = result["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["text"], "First");
}

#[test]
fn whitespace_only_jsx_text_excluded() {
    // Whitespace-only text between elements should not be detected
    let source = r#"const App = () => (
  <div>
    <span>Hello</span>
  </div>
);"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();
    // Only "Hello" should be detected, not the whitespace between tags
    let texts: Vec<&str> = items.iter().map(|i| i["text"].as_str().unwrap()).collect();
    assert!(
        texts.iter().all(|t| t.trim().len() >= 2),
        "all items should have meaningful text"
    );
}

#[test]
fn nested_excluded_component() {
    let source = r#"const App = () => (
  <div>
    <Trans>
      <span>Nested text</span>
    </Trans>
  </div>
);"#;
    let result = extract(source, "tsx");
    let items = result["items"].as_array().unwrap();
    // "Nested text" inside <Trans><span> should still be excluded
    let has_nested = items
        .iter()
        .any(|i| i["text"].as_str().unwrap() == "Nested text");
    assert!(!has_nested, "text nested inside <Trans> should be excluded");
}
