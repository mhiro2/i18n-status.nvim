use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

use crate::scan::TranslationFramework;

/// Maximum nesting depth for our hand-written recursive descent over untrusted input
/// (the resource JSON scanner). Pathologically deep structures are turned into errors
/// instead of overflowing the stack, which would abort the whole server process.
pub const MAX_RECURSION_DEPTH: usize = 256;

/// Stack size for the thread the server runs on. The swc parser recurses on syntactic
/// nesting and even drops its AST recursively, so deeply nested *source* (e.g. long
/// operator/member chains or nested parens) can overflow the default stack and abort
/// the process. A guard on our own visitors cannot help because the overflow happens
/// inside swc's parse/drop before/around them, so we give the whole server a large
/// stack to absorb realistic-to-very-deep inputs instead.
pub const SERVER_STACK_SIZE: usize = 256 * 1024 * 1024;

/// Upper bound on source size handed to the swc parser. Nesting depth is bounded by
/// input length, so capping the size keeps the worst-case parse/drop recursion within
/// `SERVER_STACK_SIZE`, turning absurdly large inputs into a graceful error instead of
/// a stack overflow. Hand-written i18n source is far smaller than this.
pub const MAX_SOURCE_BYTES: usize = 4 * 1024 * 1024;

/// Flatten a nested JSON object into dot-separated keys.
/// e.g. {"a": {"b": "c"}} -> {"a.b": "c"}
pub fn flatten_table(value: &Value, prefix: &str) -> BTreeMap<String, String> {
    let mut result = BTreeMap::new();
    flatten_recursive(value, prefix, &mut result);
    result
}

fn flatten_recursive(value: &Value, prefix: &str, result: &mut BTreeMap<String, String>) {
    match value {
        Value::Object(map) => {
            for (key, val) in map {
                let new_prefix = if prefix.is_empty() {
                    key.clone()
                } else {
                    format!("{}.{}", prefix, key)
                };
                flatten_recursive(val, &new_prefix, result);
            }
        }
        Value::String(s) => {
            result.insert(prefix.to_string(), s.clone());
        }
        _ => {
            // Numbers, booleans, etc. are converted to string
            result.insert(prefix.to_string(), value.to_string());
        }
    }
}

/// Extract placeholder names from a translation value.
///
/// next-intl messages are parsed as ICU MessageFormat: plain arguments, typed arguments such as
/// `{count, number}`, and the nested messages of `plural`, `selectordinal`, and `select`, with
/// apostrophe quoting. Other messages (i18next, or of unknown origin) read i18next `{{name}}`
/// interpolation and single-brace arguments; apostrophes are plain text there.
pub fn extract_placeholders(text: &str, framework: Option<TranslationFramework>) -> Vec<String> {
    let mut parser = PlaceholderParser {
        bytes: text.as_bytes(),
        text,
        i18next: framework != Some(TranslationFramework::NextIntl),
        pos: 0,
        names: BTreeSet::new(),
    };
    parser.message(0, false);
    parser.names.into_iter().collect()
}

struct PlaceholderParser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    /// Whether `{{name}}` is i18next interpolation rather than ICU syntax.
    i18next: bool,
    pos: usize,
    names: BTreeSet<String>,
}

impl<'a> PlaceholderParser<'a> {
    fn peek(&self, offset: usize) -> Option<u8> {
        self.bytes.get(self.pos + offset).copied()
    }

    /// Parse message text. Nested messages (`depth > 0`) end at the `}` that closes their
    /// plural/select option; at the top level a stray `}` is plain text.
    fn message(&mut self, depth: usize, in_plural: bool) {
        while let Some(byte) = self.peek(0) {
            match byte {
                b'{' if self.i18next && self.peek(1) == Some(b'{') => self.i18next_placeholder(),
                b'{' => self.icu_argument(depth),
                b'}' if depth > 0 => return,
                b'\'' if !self.i18next => self.apostrophe(in_plural),
                _ => self.pos += 1,
            }
        }
    }

    fn i18next_placeholder(&mut self) {
        let start = self.pos + 2;
        let Some(length) = self.text[start..].find("}}") else {
            self.pos = start;
            return;
        };
        let body = &self.text[start..start + length];
        // `{{- name}}` is unescaped interpolation and `{{name, format}}` applies a formatter.
        let name = body.split(',').next().unwrap_or("").trim();
        self.push_name(name.strip_prefix('-').map_or(name, str::trim_start));
        self.pos = start + length + 2;
    }

    fn apostrophe(&mut self, in_plural: bool) {
        match self.peek(1) {
            Some(b'\'') => self.pos += 2,
            // An apostrophe opens a quote only before ICU syntax; `#` is syntax inside plurals.
            Some(b'{' | b'}' | b'<' | b'>') => self.skip_quoted(),
            Some(b'#') if in_plural => self.skip_quoted(),
            _ => self.pos += 1,
        }
    }

    /// Skip quoted literal text through the next unpaired apostrophe.
    fn skip_quoted(&mut self) {
        self.pos += 1;
        while let Some(byte) = self.peek(0) {
            self.pos += 1;
            if byte == b'\'' {
                if self.peek(0) == Some(b'\'') {
                    self.pos += 1;
                } else {
                    break;
                }
            }
        }
    }

    fn icu_argument(&mut self, depth: usize) {
        self.pos += 1;
        let name = self.take_segment();
        if self.peek(0) == Some(b'}') {
            self.push_name(name);
            self.pos += 1;
            return;
        }
        if self.peek(0).is_none() {
            return;
        }
        self.pos += 1;
        let argument_type = self.take_segment();
        self.push_name(name);
        match argument_type {
            "plural" | "selectordinal" | "select" if self.peek(0) == Some(b',') => {
                self.pos += 1;
                self.options(depth, argument_type != "select");
            }
            _ => self.skip_argument_style(),
        }
    }

    /// Parse `selector {message}` pairs up to the `}` that closes the argument.
    fn options(&mut self, depth: usize, plural: bool) {
        while let Some(byte) = self.peek(0) {
            match byte {
                b'}' => {
                    self.pos += 1;
                    return;
                }
                b'{' => {
                    self.pos += 1;
                    if depth >= MAX_RECURSION_DEPTH {
                        self.skip_argument_style();
                        continue;
                    }
                    self.message(depth + 1, plural);
                    if self.peek(0) == Some(b'}') {
                        self.pos += 1;
                    }
                }
                _ => self.pos += 1,
            }
        }
    }

    /// Skip a simple argument's style (e.g. `{n, number, ::currency/EUR}`) through its `}`.
    fn skip_argument_style(&mut self) {
        let mut open = 1usize;
        while let Some(byte) = self.peek(0) {
            self.pos += 1;
            match byte {
                b'{' => open += 1,
                b'}' => {
                    open -= 1;
                    if open == 0 {
                        return;
                    }
                }
                _ => {}
            }
        }
    }

    /// Take the trimmed text up to the next `,` or `}` of an argument.
    fn take_segment(&mut self) -> &'a str {
        let start = self.pos;
        while let Some(byte) = self.peek(0) {
            if matches!(byte, b',' | b'}') {
                break;
            }
            self.pos += 1;
        }
        self.text[start..self.pos].trim()
    }

    fn push_name(&mut self, name: &str) {
        let valid = !name.is_empty()
            && !name.contains(|c: char| c.is_whitespace() || matches!(c, '{' | '}' | '\''));
        if valid {
            self.names.insert(name.to_string());
        }
    }
}

/// Check if two values have equivalent placeholders.
pub fn placeholder_equal(a: &[String], b: &[String]) -> bool {
    a == b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_flatten_simple() {
        let value: Value = serde_json::json!({
            "login": {
                "title": "Login",
                "button": "Submit"
            }
        });
        let result = flatten_table(&value, "");
        assert_eq!(result.get("login.title").unwrap(), "Login");
        assert_eq!(result.get("login.button").unwrap(), "Submit");
    }

    #[test]
    fn test_extract_placeholders_i18next() {
        let result = extract_placeholders("Hello {{name}}, you have {{count}} items", None);
        assert_eq!(result, vec!["count", "name"]);
    }

    #[test]
    fn test_extract_placeholders_icu() {
        let result = extract_placeholders("Hello {name}, you have {count} items", None);
        assert_eq!(result, vec!["count", "name"]);
    }

    #[test]
    fn test_extract_placeholders_icu_plural_and_select() {
        let result = extract_placeholders(
            "You have {count, plural, one {# item from {sender}} other {# items}} for {gender, select, female {her} other {them}}",
            None,
        );
        assert_eq!(result, vec!["count", "gender", "sender"]);
    }

    #[test]
    fn test_extract_placeholders_icu_typed_arguments_ignore_spacing() {
        assert_eq!(
            extract_placeholders("{count, number}", None),
            extract_placeholders("{count,number}", None)
        );
        assert_eq!(
            extract_placeholders(
                "Total {price, number, ::currency/EUR} on {day, date, short}",
                None
            ),
            vec!["day", "price"]
        );
    }

    #[test]
    fn test_extract_placeholders_icu_quoted_braces_are_literal() {
        let next_intl = Some(TranslationFramework::NextIntl);
        assert!(extract_placeholders("Use '{name}' literally, it''s fine", next_intl).is_empty());
        assert_eq!(extract_placeholders("It's {name}", next_intl), vec!["name"]);
    }

    #[test]
    fn test_extract_placeholders_i18next_variants() {
        assert_eq!(
            extract_placeholders("{{- html}} on {{date, datetime}} in '{{place}}'", None),
            vec!["date", "html", "place"]
        );
    }

    #[test]
    fn test_extract_placeholders_top_level_closing_brace_is_text() {
        assert_eq!(
            extract_placeholders("Use } for {{name}} and {count}", None),
            vec!["count", "name"]
        );
    }

    #[test]
    fn test_extract_placeholders_next_intl_quotes_double_braces_and_tags() {
        let next_intl = Some(TranslationFramework::NextIntl);
        assert!(extract_placeholders("'{{name}}'", next_intl).is_empty());
        assert!(extract_placeholders("'{{'name'}}'", next_intl).is_empty());
        assert!(extract_placeholders("'<b>{name}</b>'", next_intl).is_empty());
        assert_eq!(
            extract_placeholders("<b>{name}</b>", next_intl),
            vec!["name"]
        );
    }

    #[test]
    fn test_extract_placeholders_i18next_apostrophes_are_text() {
        let i18next = Some(TranslationFramework::I18next);
        assert_eq!(extract_placeholders("'{{name}}'", i18next), vec!["name"]);
        assert_eq!(
            extract_placeholders("'<b>{{name}}</b>' and '{count}'", i18next),
            vec!["count", "name"]
        );
    }

    #[test]
    fn test_extract_placeholders_plural_hash_quote() {
        let next_intl = Some(TranslationFramework::NextIntl);
        assert_eq!(
            extract_placeholders("{count, plural, other {'# {name}'}}", next_intl),
            vec!["count"]
        );
        assert_eq!(
            extract_placeholders("{gender, select, other {'# {name}'}}", next_intl),
            vec!["gender", "name"]
        );
    }

    #[test]
    fn test_extract_placeholders_unbalanced_input_does_not_panic() {
        for text in [
            "{",
            "{count, plural, one {",
            "{{name",
            "'{",
            "}{,",
            "{a, select, x {{{",
        ] {
            let _ = extract_placeholders(text, None);
        }
    }

    #[test]
    fn test_extract_placeholders_deep_nesting_is_bounded() {
        let levels = MAX_RECURSION_DEPTH * 4;
        let mut text: String = (0..levels)
            .map(|level| format!("{{a{level}, select, x {{"))
            .collect();
        text.push_str(&"}}".repeat(levels));

        // Arguments up to the depth limit are collected; deeper option bodies are skipped.
        let mut expected: Vec<String> = (0..=MAX_RECURSION_DEPTH)
            .map(|level| format!("a{level}"))
            .collect();
        expected.sort();
        assert_eq!(extract_placeholders(&text, None), expected);
    }

    #[test]
    fn test_placeholder_equal() {
        assert!(placeholder_equal(
            &extract_placeholders("Hello {{name}}", None),
            &extract_placeholders("こんにちは {{name}}", None)
        ));
        assert!(!placeholder_equal(
            &extract_placeholders("Hello {{name}}", None),
            &extract_placeholders("Hello {{user}}", None)
        ));
        assert!(!placeholder_equal(
            &extract_placeholders(
                "You have {count, plural, one {# item} other {# items}}",
                None
            ),
            &extract_placeholders("商品があります", None)
        ));
    }
}
