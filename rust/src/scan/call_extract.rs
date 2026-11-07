use swc_common::{SourceMap, SourceMapper, Spanned};
use swc_ecma_ast::*;
use swc_ecma_visit::{Visit, VisitWith};

use super::const_eval::{KeyCandidate, eval_key_candidates};
use super::parser::span_to_byte_range;
use super::scope::{ScopeAnalysis, SymbolBinding};
use super::{
    ExtractResult, NamespaceResolution, Range, ScanItem, TranslationFramework, UnresolvedReason,
    UnresolvedRef,
};

/// Longest key expression kept for display, in characters.
const MAX_EXPRESSION_CHARS: usize = 80;

pub(super) fn extract_calls(
    module: &Module,
    cm: &SourceMap,
    scopes: &ScopeAnalysis,
    fallback_namespace: &str,
    range: &Option<Range>,
) -> ExtractResult {
    let mut result = ExtractResult::default();
    let mut visitor = CallVisitor {
        cm,
        scopes,
        fallback_namespace,
        range,
        result: &mut result,
    };
    module.visit_with(&mut visitor);
    result
}

struct CallVisitor<'a> {
    cm: &'a SourceMap,
    scopes: &'a ScopeAnalysis,
    fallback_namespace: &'a str,
    range: &'a Option<Range>,
    result: &'a mut ExtractResult,
}

/// Source text of `expr` on one line, shortened to `MAX_EXPRESSION_CHARS`.
fn expression_text(cm: &SourceMap, expr: &Expr) -> String {
    let snippet = cm.span_to_snippet(expr.span()).unwrap_or_default();
    let collapsed = snippet.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= MAX_EXPRESSION_CHARS {
        return collapsed;
    }
    let mut shortened: String = collapsed.chars().take(MAX_EXPRESSION_CHARS - 1).collect();
    shortened.push('…');
    shortened
}

impl Visit for CallVisitor<'_> {
    fn visit_call_expr(&mut self, call: &CallExpr) {
        self.check_call(call);
        call.visit_children_with(self);
    }
}

impl<'a> CallVisitor<'a> {
    fn check_call(&mut self, call: &CallExpr) {
        let Callee::Expr(callee) = &call.callee else {
            return;
        };
        let call_pos = call.span.lo.0;
        let binding = match callee.as_ref() {
            Expr::Ident(ident) => {
                let func_name = ident.sym.as_ref();
                if self.scopes.is_hook_call(func_name, call_pos)
                    || !self.is_translation_call(func_name, call_pos)
                {
                    return;
                }
                self.scopes
                    .resolve(func_name, call_pos)
                    .filter(|binding| binding.is_callable_translator_at(call_pos))
            }
            Expr::Member(member) => {
                let MemberProp::Ident(prop) = &member.prop else {
                    return;
                };
                match (member.obj.as_ref(), prop.sym.as_ref()) {
                    // next-intl translators also format messages through `t.rich`, `t.markup`, and `t.raw`.
                    (Expr::Ident(receiver), "rich" | "markup" | "raw") => {
                        let Some(binding) = self
                            .scopes
                            .resolve(receiver.sym.as_ref(), call_pos)
                            .filter(|binding| {
                                binding.is_callable_translator_at(call_pos)
                                    && binding.framework == Some(TranslationFramework::NextIntl)
                            })
                        else {
                            return;
                        };
                        Some(binding)
                    }
                    (_, "t") => None,
                    _ => return,
                }
            }
            _ => return,
        };

        let Some(first_arg) = call.args.first() else {
            return;
        };

        let (lnum, col, end_lnum, end_col) = span_to_byte_range(self.cm, first_arg.expr.span());
        if let Some(range) = self.range
            && (lnum < range.start_line || lnum > range.end_line)
        {
            return;
        }

        let candidates =
            eval_key_candidates(&first_arg.expr, &|ident| self.scopes.const_value(ident));
        let mut prefixes = Vec::new();
        let reason = match &candidates {
            None => {
                prefixes.push(String::new());
                Some(UnresolvedReason::Limit)
            }
            Some(candidates) => {
                prefixes.extend(candidates.iter().filter_map(|candidate| match candidate {
                    KeyCandidate::Prefix(prefix) => Some(prefix.clone()),
                    KeyCandidate::Exact(_) => None,
                }));
                if prefixes.is_empty() {
                    None
                } else if prefixes.iter().any(String::is_empty) {
                    Some(UnresolvedReason::Dynamic)
                } else {
                    Some(UnresolvedReason::Partial)
                }
            }
        };
        if let Some(reason) = reason {
            let mut key_prefixes: Vec<String> = Vec::new();
            let mut unbounded = false;
            for prefix in &prefixes {
                let (ranges, any_key) = self.key_ranges(prefix, binding);
                unbounded |= any_key;
                for range in ranges {
                    if !key_prefixes.contains(&range) {
                        key_prefixes.push(range);
                    }
                }
            }
            self.result.unresolved.push(UnresolvedRef {
                lnum,
                col,
                end_lnum,
                end_col,
                reason,
                expression: expression_text(self.cm, &first_arg.expr),
                key_prefixes,
                unbounded,
            });
        }

        let refactorable = is_direct_literal(&first_arg.expr);
        for candidate in candidates.into_iter().flatten() {
            let KeyCandidate::Exact(value) = candidate else {
                continue;
            };
            let (key, namespace, fallback) = self.resolve_namespace(&value, binding);
            self.result.items.push(ScanItem {
                key,
                raw: value,
                namespace,
                lnum,
                col,
                end_lnum,
                end_col,
                fallback,
                refactorable,
                framework: binding.and_then(|binding| binding.framework),
                source_key_policy: binding.and_then(|binding| binding.source_key_policy),
                translator_namespace: binding.and_then(|binding| binding.namespace.clone()),
                opaque_binding: binding.is_some_and(SymbolBinding::has_opaque_keys),
            });
        }
    }

    fn is_translation_call(&self, func_name: &str, call_pos: u32) -> bool {
        if let Some(binding) = self.scopes.resolve(func_name, call_pos) {
            return binding.is_callable_translator_at(call_pos);
        }
        func_name == "t"
    }

    /// Canonical `namespace:path` prefixes of the keys whose source spelling starts with
    /// `prefix`, and whether such a key may also be any other key.
    ///
    /// An i18next key may carry its own `ns:` in the runtime part, which replaces the bound
    /// namespace: the key then starts with `prefix` itself (its namespace starts with it), and an
    /// empty prefix may reach any key.
    fn key_ranges(&self, prefix: &str, binding: Option<&SymbolBinding>) -> (Vec<String>, bool) {
        if binding.is_some_and(SymbolBinding::has_opaque_keys) {
            return (Vec::new(), true);
        }
        if let Some(binding) =
            binding.filter(|binding| binding.framework == Some(TranslationFramework::NextIntl))
        {
            let path = match binding.namespace.as_deref() {
                Some(namespace) => format!("{namespace}.{prefix}"),
                None => prefix.to_string(),
            };
            return match path.split_once('.') {
                Some((namespace, key_path)) if !namespace.is_empty() => {
                    (vec![format!("{namespace}:{key_path}")], false)
                }
                _ => (Vec::new(), true),
            };
        }
        if prefix.contains(':') {
            return (vec![prefix.to_string()], false);
        }
        let namespace = binding
            .and_then(|binding| binding.namespace.as_deref())
            .or((!prefix.is_empty()).then_some(self.fallback_namespace));
        let mut ranges: Vec<String> = namespace
            .map(|namespace| format!("{namespace}:{prefix}"))
            .into_iter()
            .collect();
        if !prefix.is_empty() {
            ranges.push(prefix.to_string());
        }
        (ranges, prefix.is_empty())
    }

    fn resolve_namespace(
        &self,
        value: &str,
        binding: Option<&SymbolBinding>,
    ) -> (String, String, bool) {
        if let Some(resolved) = binding.and_then(|binding| next_intl_key(value, binding)) {
            return resolved;
        }

        if let Some(colon_pos) = value.find(':') {
            let namespace = &value[..colon_pos];
            return (value.to_string(), namespace.to_string(), false);
        }

        if let Some(namespace) = binding.and_then(|binding| binding.namespace.as_ref()) {
            return (format!("{}:{}", namespace, value), namespace.clone(), false);
        }

        let namespace = self.fallback_namespace.to_string();
        (format!("{}:{}", namespace, value), namespace, true)
    }
}

/// Canonical `namespace:path` of a next-intl reference.
///
/// next-intl joins the bound namespace and the source key into one dot-separated message path,
/// so nested namespaces (`useTranslations("Home.Form")`) and root translators
/// (`useTranslations()` with `t("Home.title")`) both resolve to the top-level message object as
/// the namespace. `:` has no meaning in next-intl keys. Translators with a dynamic namespace, or
/// paths without a namespace segment, fall back to the generic resolution.
fn next_intl_key(value: &str, binding: &SymbolBinding) -> Option<(String, String, bool)> {
    if binding.framework != Some(TranslationFramework::NextIntl) {
        return None;
    }
    let path = match (binding.namespace_resolution?, binding.namespace.as_deref()) {
        (NamespaceResolution::Static, Some(namespace)) => format!("{namespace}.{value}"),
        (NamespaceResolution::Absent, _) => value.to_string(),
        _ => return None,
    };
    let (namespace, key_path) = path.split_once('.')?;
    if namespace.is_empty() || key_path.is_empty() {
        return None;
    }
    Some((
        format!("{namespace}:{key_path}"),
        namespace.to_string(),
        false,
    ))
}

fn is_direct_literal(expr: &Expr) -> bool {
    match expr {
        Expr::Lit(Lit::Str(_)) => true,
        Expr::Tpl(template) => template.exprs.is_empty(),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use std::fmt::Write as _;

    use super::*;
    use crate::scan::parser::parse_module;
    use crate::scan::scope::collect_scopes_precise;
    use crate::scan::{SourceKeyPolicy, TranslationFramework};

    fn extract_all(source: &str, fallback_namespace: &str) -> ExtractResult {
        let (module, cm) = parse_module(source, "tsx").expect("source should parse");
        let scopes = collect_scopes_precise(&module, &cm);
        extract_calls(&module, &cm, &scopes, fallback_namespace, &None)
    }

    fn extract_items(source: &str, fallback_namespace: &str) -> Vec<ScanItem> {
        extract_all(source, fallback_namespace).items
    }

    #[test]
    fn extracts_calls_from_scoped_alias() {
        let items = extract_items(
            r#"
function Page() {
  const { t: tt } = useTranslation("home");
  return tt("title");
}
"#,
            "translation",
        );

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "home:title");
        assert_eq!(items[0].namespace, "home");
        assert!(!items[0].fallback);
    }

    #[test]
    fn falls_back_for_member_t_calls_without_scope() {
        let items = extract_items(r#"i18n.t("greeting");"#, "translation");

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "translation:greeting");
        assert_eq!(items[0].namespace, "translation");
        assert!(items[0].fallback);
    }

    #[test]
    fn shadowed_const_keys_are_not_resolved_statically() {
        let items = extract_items(
            r#"
const key = "outer";
function A(key) { return t(key); }
function B() { let key = "inner"; return t(key); }
function C() { const key = readKey(); return t(key); }
"#,
            "translation",
        );

        assert!(items.is_empty(), "unexpected items: {items:?}");
    }

    #[test]
    fn same_line_block_const_does_not_leak_into_outer_call() {
        let items = extract_items(
            r#"const key = "outer"; { const key = "inner"; t(key); } t(key);"#,
            "translation",
        );

        let keys: Vec<_> = items.iter().map(|item| item.key.as_str()).collect();
        assert_eq!(keys, ["translation:inner", "translation:outer"]);
    }

    #[test]
    fn reports_translator_framework_and_source_key_policy() {
        let items = extract_items(
            r#"
function Page() {
  const t = useTranslations("common");
  const { t: i18nT } = useTranslation("admin");
  return [t("title"), i18nT("save"), i18n.t("loose")];
}
"#,
            "translation",
        );

        assert_eq!(items.len(), 3);
        assert!(matches!(
            items[0].framework,
            Some(TranslationFramework::NextIntl)
        ));
        assert!(matches!(
            items[0].source_key_policy,
            Some(SourceKeyPolicy::NamespaceRelative)
        ));
        assert!(matches!(
            items[1].framework,
            Some(TranslationFramework::I18next)
        ));
        assert!(matches!(
            items[1].source_key_policy,
            Some(SourceKeyPolicy::Canonical)
        ));
        assert!(items[2].framework.is_none());
        assert!(items[2].source_key_policy.is_none());
    }

    #[test]
    fn next_intl_nested_namespace_resolves_to_top_level_namespace() {
        let items = extract_items(
            r#"
function Page() {
  const t = useTranslations("Home.Form");
  return t("fields.title");
}
"#,
            "translation",
        );

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "Home:Form.fields.title");
        assert_eq!(items[0].namespace, "Home");
        assert_eq!(items[0].raw, "fields.title");
        assert_eq!(items[0].translator_namespace.as_deref(), Some("Home.Form"));
        assert!(!items[0].fallback);
    }

    #[test]
    fn next_intl_root_translator_reads_namespace_from_the_key_path() {
        let items = extract_items(
            r#"
async function Page() {
  const t = await getTranslations();
  return [t("Home.title"), t("Home.Form.submit")];
}
"#,
            "translation",
        );

        let keys: Vec<_> = items.iter().map(|item| item.key.as_str()).collect();
        assert_eq!(keys, ["Home:title", "Home:Form.submit"]);
        assert!(items.iter().all(|item| item.namespace == "Home"));
        assert!(items.iter().all(|item| !item.fallback));
        assert!(items.iter().all(|item| item.translator_namespace.is_none()));
        assert!(matches!(
            items[0].source_key_policy,
            Some(SourceKeyPolicy::Canonical)
        ));
    }

    #[test]
    fn next_intl_keys_do_not_treat_colon_as_namespace_separator() {
        let items = extract_items(
            r#"
function Page() {
  const t = useTranslations("Home");
  return t("time:label");
}
"#,
            "translation",
        );

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "Home:time:label");
        assert_eq!(items[0].namespace, "Home");
    }

    #[test]
    fn next_intl_dynamic_namespace_falls_back_without_a_source_key_policy() {
        let items = extract_items(
            r#"
function Page({ ns }) {
  const t = useTranslations(ns);
  return t("Form.title");
}
"#,
            "translation",
        );

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "translation:Form.title");
        assert!(items[0].fallback);
        assert!(items[0].source_key_policy.is_none());
    }

    #[test]
    fn extracts_next_intl_translator_methods() {
        let items = extract_items(
            r#"
function Page() {
  const t = useTranslations("Home");
  return [t.rich("title", {}), t.markup("body", {}), t.raw("data"), t.has("flag")];
}
"#,
            "translation",
        );

        let keys: Vec<_> = items.iter().map(|item| item.key.as_str()).collect();
        assert_eq!(keys, ["Home:title", "Home:body", "Home:data"]);
        assert!(items.iter().all(|item| item.refactorable));
        assert!(
            items
                .iter()
                .all(|item| matches!(item.framework, Some(TranslationFramework::NextIntl)))
        );
    }

    #[test]
    fn translator_methods_require_a_next_intl_binding() {
        let items = extract_items(
            r#"
function Page() {
  const { t } = useTranslation("common");
  const rich = { rich: (key) => key };
  return [t.rich("title"), rich.rich("body"), other.raw("data")];
}
"#,
            "translation",
        );

        assert!(items.is_empty(), "unexpected items: {items:?}");
    }

    #[test]
    fn flags_translators_whose_keys_cannot_be_spelled_from_metadata() {
        let items = extract_items(
            r#"
import { t as globalT } from "i18next";
function Page({ ns }) {
  const { t } = useTranslation("auth", { keyPrefix: "login" });
  const { t: plain } = useTranslation("auth", { useSuspense: false });
  const { t: dynamic } = useTranslation(ns);
  const next = useTranslations(ns);
  return [t("title"), plain("title"), dynamic("title"), next("title"), globalT("title")];
}
"#,
            "translation",
        );

        let flags: Vec<_> = items.iter().map(|item| item.opaque_binding).collect();
        assert_eq!(flags, [true, false, true, true, false]);
    }

    #[test]
    fn reports_unresolved_calls_with_their_canonical_key_range() {
        let result = extract_all(
            r#"
function Page({ code, section, ns }) {
  const { t } = useTranslation("common");
  const { t: tp } = useTranslation("common", { keyPrefix: "form" });
  const nt = useTranslations("Home.Form");
  const root = useTranslations();
  return [
    t(`errors.${code}`),
    t(section),
    t(flag ? "title" : `admin:menu.${section}`),
    nt(`fields.${code}`),
    nt(code),
    root(`Auth.${code}`),
    root(code),
    tp(code),
    i18n.t(code),
    i18n.t(`banner.${code}`),
  ];
}
"#,
            "translation",
        );

        let refs: Vec<_> = result
            .unresolved
            .iter()
            .map(|reference| {
                (
                    reference.expression.as_str(),
                    reference.reason,
                    reference.key_prefixes.clone(),
                    reference.unbounded,
                )
            })
            .collect();
        let strings = |values: &[&str]| values.iter().map(ToString::to_string).collect::<Vec<_>>();
        assert_eq!(
            refs,
            [
                (
                    "`errors.${code}`",
                    UnresolvedReason::Partial,
                    strings(&["common:errors.", "errors."]),
                    false
                ),
                (
                    "section",
                    UnresolvedReason::Dynamic,
                    strings(&["common:"]),
                    true
                ),
                (
                    r#"flag ? "title" : `admin:menu.${section}`"#,
                    UnresolvedReason::Partial,
                    strings(&["admin:menu."]),
                    false
                ),
                (
                    "`fields.${code}`",
                    UnresolvedReason::Partial,
                    strings(&["Home:Form.fields."]),
                    false
                ),
                (
                    "code",
                    UnresolvedReason::Dynamic,
                    strings(&["Home:Form."]),
                    false
                ),
                (
                    "`Auth.${code}`",
                    UnresolvedReason::Partial,
                    strings(&["Auth:"]),
                    false
                ),
                ("code", UnresolvedReason::Dynamic, Vec::new(), true),
                ("code", UnresolvedReason::Dynamic, Vec::new(), true),
                ("code", UnresolvedReason::Dynamic, Vec::new(), true),
                (
                    "`banner.${code}`",
                    UnresolvedReason::Partial,
                    strings(&["translation:banner.", "banner."]),
                    false
                ),
            ]
        );
        let keys: Vec<_> = result.items.iter().map(|item| item.key.as_str()).collect();
        assert_eq!(keys, ["common:title"]);
    }

    #[test]
    fn reports_expansions_over_the_candidate_limit_as_unresolved() {
        let mut key = "\"a\"".to_string();
        for index in 0..7 {
            write!(key, " + (flag{index} ? \"a\" : \"b\")")
                .expect("writing to a string should succeed");
        }
        let source = format!("const {{ t }} = useTranslation(\"common\");\nt({key});");
        let result = extract_all(&source, "translation");

        assert!(result.items.is_empty());
        assert_eq!(result.unresolved.len(), 1);
        let reference = &result.unresolved[0];
        assert_eq!(reference.reason, UnresolvedReason::Limit);
        assert_eq!(reference.key_prefixes, ["common:"]);
        assert!(reference.unbounded);
        assert!(reference.expression.ends_with('…'));
        assert_eq!(reference.expression.chars().count(), MAX_EXPRESSION_CHARS);
    }

    #[test]
    fn member_call_does_not_borrow_a_hook_namespace() {
        let items = extract_items(
            r#"
function Page() {
  const { t } = useTranslation("home");
  return i18n.t("title");
}
"#,
            "translation",
        );

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "translation:title");
        assert!(items[0].fallback);
    }

    #[test]
    fn returns_byte_accurate_multiline_ranges_and_refactorability() {
        let source =
            "const 前置き = '値'; t(\"title\");\nt(\n  flag\n    ? \"first\"\n    : \"second\"\n);";
        let items = extract_items(source, "translation");

        assert_eq!(items.len(), 3);
        let literal_col = source.lines().next().unwrap().find("\"title\"").unwrap() as u32;
        assert_eq!(items[0].lnum, 0);
        assert_eq!(items[0].col, literal_col);
        assert_eq!(items[0].end_lnum, 0);
        assert_eq!(items[0].end_col, literal_col + 7);
        assert!(items[0].refactorable);

        for item in &items[1..] {
            assert_eq!(item.lnum, 2);
            assert_eq!(item.end_lnum, 4);
            assert!(!item.refactorable);
        }
    }

    #[test]
    fn many_reassignments_keep_scope_lookup_work_near_linear() {
        const WRITE_COUNT: usize = 4_096;
        let mut source = "const { t } = useTranslation(\"common\");\n".to_string();
        for index in 0..WRITE_COUNT {
            writeln!(source, "t(\"key{index}\"); t = formatter;")
                .expect("writing to a string should succeed");
        }

        let (module, cm) = parse_module(&source, "tsx").expect("source should parse");
        let scopes = collect_scopes_precise(&module, &cm);
        let collection_work = scopes.lookup_work();

        assert!(
            collection_work <= WRITE_COUNT * 16,
            "scope collection performed {collection_work} lookup steps"
        );

        scopes.reset_lookup_work();
        let items = extract_calls(&module, &cm, &scopes, "translation", &None).items;
        let extraction_work = scopes.lookup_work();

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "common:key0");
        assert!(
            extraction_work <= WRITE_COUNT * 96,
            "call extraction performed {extraction_work} lookup steps"
        );
    }
}
