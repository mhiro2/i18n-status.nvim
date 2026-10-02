use swc_common::{SourceMap, Spanned};
use swc_ecma_ast::*;
use swc_ecma_visit::{Visit, VisitWith};

use super::const_eval::{ConstBinding, eval_string_exprs};
use super::parser::span_to_byte_range;
use super::scope::ScopeAnalysis;
use super::{Range, ScanItem};

pub(super) fn extract_calls(
    module: &Module,
    cm: &SourceMap,
    const_bindings: &[ConstBinding],
    scopes: &ScopeAnalysis,
    fallback_namespace: &str,
    range: &Option<Range>,
) -> Vec<ScanItem> {
    let mut items = Vec::new();
    let mut visitor = CallVisitor {
        cm,
        const_bindings,
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
    const_bindings: &'a [ConstBinding],
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

        let values = eval_string_exprs(&first_arg.expr, lnum, self.const_bindings);
        if values.is_empty() {
            return;
        }

        for value in values {
            let binding_name = (!is_member_t).then_some(func_name.as_str());
            let (key, namespace, fallback) = self.resolve_namespace(&value, call_pos, binding_name);
            self.items.push(ScanItem {
                key,
                raw: value,
                namespace,
                lnum,
                col,
                end_lnum,
                end_col,
                fallback,
                refactorable: is_direct_literal(&first_arg.expr),
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
        call_pos: u32,
        binding_name: Option<&str>,
    ) -> (String, String, bool) {
        if let Some(colon_pos) = value.find(':') {
            let namespace = &value[..colon_pos];
            return (value.to_string(), namespace.to_string(), false);
        }

        if let Some(binding_name) = binding_name
            && let Some(binding) = self.scopes.resolve(binding_name, call_pos)
            && binding.is_callable_translator_at(call_pos)
            && let Some(namespace) = &binding.namespace
        {
            return (format!("{}:{}", namespace, value), namespace.clone(), false);
        }

        let namespace = self.fallback_namespace.to_string();
        (format!("{}:{}", namespace, value), namespace, true)
    }
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
    use crate::scan::const_eval::collect_consts;
    use crate::scan::parser::parse_module;
    use crate::scan::scope::collect_scopes_precise;

    fn extract_items(source: &str, fallback_namespace: &str) -> Vec<ScanItem> {
        let (module, cm) = parse_module(source, "tsx").expect("source should parse");
        let const_bindings = collect_consts(&module, &cm);
        let scopes = collect_scopes_precise(&module, &cm, &const_bindings);
        extract_calls(
            &module,
            &cm,
            &const_bindings,
            &scopes,
            fallback_namespace,
            &None,
        )
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
        let const_bindings = collect_consts(&module, &cm);
        let scopes = collect_scopes_precise(&module, &cm, &const_bindings);
        let collection_work = scopes.lookup_work();

        assert!(
            collection_work <= WRITE_COUNT * 16,
            "scope collection performed {collection_work} lookup steps"
        );

        scopes.reset_lookup_work();
        let items = extract_calls(&module, &cm, &const_bindings, &scopes, "translation", &None);
        let extraction_work = scopes.lookup_work();

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "common:key0");
        assert!(
            extraction_work <= WRITE_COUNT * 96,
            "call extraction performed {extraction_work} lookup steps"
        );
    }
}
