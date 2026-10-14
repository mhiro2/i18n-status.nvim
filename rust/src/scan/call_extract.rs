use swc_common::{SourceMap, Spanned};
use swc_ecma_ast::*;
use swc_ecma_visit::{Visit, VisitWith};

use super::const_eval::eval_string_exprs;
use super::parser::span_to_byte_range;
use super::scope::{ScopeAnalysis, SymbolBinding};
use super::{NamespaceResolution, Range, ScanItem, TranslationFramework};

pub(super) fn extract_calls(
    module: &Module,
    cm: &SourceMap,
    scopes: &ScopeAnalysis,
    fallback_namespace: &str,
    range: &Option<Range>,
) -> Vec<ScanItem> {
    let mut items = Vec::new();
    let mut visitor = CallVisitor {
        cm,
        scopes,
        fallback_namespace,
        range,
        items: &mut items,
    };
    module.visit_with(&mut visitor);
    items
}

struct CallVisitor<'a> {
    cm: &'a SourceMap,
    scopes: &'a ScopeAnalysis,
    fallback_namespace: &'a str,
    range: &'a Option<Range>,
    items: &'a mut Vec<ScanItem>,
}

impl Visit for CallVisitor<'_> {
    fn visit_call_expr(&mut self, call: &CallExpr) {
        self.check_call(call);
        call.visit_children_with(self);
    }
}

impl<'a> CallVisitor<'a> {
    fn check_call(&mut self, call: &CallExpr) {
        let (func_name, is_member_t) = match &call.callee {
            Callee::Expr(expr) => match expr.as_ref() {
                Expr::Ident(ident) => (ident.sym.to_string(), false),
                Expr::Member(member) => {
                    if let MemberProp::Ident(prop) = &member.prop {
                        if prop.sym.as_ref() == "t" {
                            ("t".to_string(), true)
                        } else {
                            return;
                        }
                    } else {
                        return;
                    }
                }
                _ => return,
            },
            _ => return,
        };

        let call_pos = call.span.lo.0;
        if !is_member_t && self.scopes.is_hook_call(&func_name, call_pos) {
            return;
        }
        if !is_member_t && !self.is_translation_call(&func_name, call) {
            return;
        }

        let Some(first_arg) = call.args.first() else {
            return;
        };

        let (lnum, col, end_lnum, end_col) = span_to_byte_range(self.cm, first_arg.expr.span());
        if let Some(range) = self.range
            && (lnum < range.start_line || lnum > range.end_line)
        {
            return;
        }

        let values = eval_string_exprs(&first_arg.expr, &|ident| self.scopes.const_value(ident));
        if values.is_empty() {
            return;
        }

        let binding = (!is_member_t)
            .then(|| self.scopes.resolve(&func_name, call_pos))
            .flatten()
            .filter(|binding| binding.is_callable_translator_at(call_pos));
        let refactorable = is_direct_literal(&first_arg.expr);
        for value in values {
            let (key, namespace, fallback) = self.resolve_namespace(&value, binding);
            self.items.push(ScanItem {
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
            });
        }
    }

    fn is_translation_call(&self, func_name: &str, call: &CallExpr) -> bool {
        let call_pos = call.span.lo.0;
        if let Some(binding) = self.scopes.resolve(func_name, call_pos) {
            return binding.is_callable_translator_at(call_pos);
        }
        func_name == "t"
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

    fn extract_items(source: &str, fallback_namespace: &str) -> Vec<ScanItem> {
        let (module, cm) = parse_module(source, "tsx").expect("source should parse");
        let scopes = collect_scopes_precise(&module, &cm);
        extract_calls(&module, &cm, &scopes, fallback_namespace, &None)
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
    fn resolves_each_translator_alias_to_its_own_namespace() {
        let items = extract_items(
            r#"
function Page() {
  const { t: commonT } = useTranslation("common");
  const { t: adminT } = useTranslation("admin");
  return [commonT("title"), adminT("save")];
}
"#,
            "translation",
        );

        assert_eq!(items.len(), 2);
        assert_eq!(items[0].key, "common:title");
        assert_eq!(items[1].key, "admin:save");
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
        let items = extract_calls(&module, &cm, &scopes, "translation", &None);
        let extraction_work = scopes.lookup_work();

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "common:key0");
        assert!(
            extraction_work <= WRITE_COUNT * 96,
            "call extraction performed {extraction_work} lookup steps"
        );
    }
}
