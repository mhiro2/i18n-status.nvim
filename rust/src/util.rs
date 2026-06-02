use serde_json::Value;
use std::collections::BTreeMap;

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
/// Supports both {{name}} (i18next) and {name} (next-intl / ICU) formats.
pub fn extract_placeholders(text: &str) -> Vec<String> {
    let mut placeholders = Vec::new();
    let mut pos = 0; // byte offset

    while pos < text.len() {
        if text.as_bytes()[pos] == b'{' {
            let double = pos + 1 < text.len() && text.as_bytes()[pos + 1] == b'{';
            let start = if double { pos + 2 } else { pos + 1 };
            let end_marker = if double { "}}" } else { "}" };

            if let Some(end_pos) = text[start..].find(end_marker) {
                let name = &text[start..start + end_pos];
                let name = name.trim();
                if !name.is_empty() && !name.contains(' ') {
                    placeholders.push(name.to_string());
                }
                pos = start + end_pos + end_marker.len();
            } else {
                pos += 1;
            }
        } else {
            pos += text[pos..].chars().next().map_or(1, |c| c.len_utf8());
        }
    }

    placeholders.sort();
    placeholders.dedup();
    placeholders
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
        let result = extract_placeholders("Hello {{name}}, you have {{count}} items");
        assert_eq!(result, vec!["count", "name"]);
    }

    #[test]
    fn test_extract_placeholders_icu() {
        let result = extract_placeholders("Hello {name}, you have {count} items");
        assert_eq!(result, vec!["count", "name"]);
    }

    #[test]
    fn test_placeholder_equal() {
        assert!(placeholder_equal(
            &extract_placeholders("Hello {{name}}"),
            &extract_placeholders("こんにちは {{name}}")
        ));
        assert!(!placeholder_equal(
            &extract_placeholders("Hello {{name}}"),
            &extract_placeholders("Hello {{user}}")
        ));
    }
}
