use swc_common::{SourceMap, Spanned};
use swc_ecma_ast::*;

use super::const_eval::{ConstBinding, eval_string_exprs};
use super::parser::span_to_loc;
use super::scope::{NamespaceScope, is_translation_hook};
use super::{Range, ScanItem};

pub(super) fn extract_calls(
    module: &Module,
    cm: &SourceMap,
    const_bindings: &[ConstBinding],
    scopes: &[NamespaceScope],
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
    for item in &module.body {
        visitor.visit_module_item(item);
    }
    items
}

struct CallVisitor<'a> {
    cm: &'a SourceMap,
    const_bindings: &'a [ConstBinding],
    scopes: &'a [NamespaceScope],
    fallback_namespace: &'a str,
    range: &'a Option<Range>,
    items: &'a mut Vec<ScanItem>,
}

impl<'a> CallVisitor<'a> {
    fn visit_module_item(&mut self, item: &ModuleItem) {
        match item {
            ModuleItem::Stmt(stmt) => self.visit_stmt(stmt),
            ModuleItem::ModuleDecl(decl) => self.visit_module_decl(decl),
        }
    }

    fn visit_module_decl(&mut self, decl: &ModuleDecl) {
        match decl {
            ModuleDecl::ExportDecl(export) => self.visit_decl(&export.decl),
            ModuleDecl::ExportDefaultExpr(export) => self.visit_expr(&export.expr),
            ModuleDecl::ExportDefaultDecl(export) => {
                if let DefaultDecl::Fn(fn_expr) = &export.decl {
                    if let Some(body) = &fn_expr.function.body {
                        for stmt in &body.stmts {
                            self.visit_stmt(stmt);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn visit_stmt(&mut self, stmt: &Stmt) {
        match stmt {
            Stmt::Expr(expr_stmt) => self.visit_expr(&expr_stmt.expr),
            Stmt::Decl(decl) => self.visit_decl(decl),
            Stmt::Return(ret) => {
                if let Some(arg) = &ret.arg {
                    self.visit_expr(arg);
                }
            }
            Stmt::Block(block) => {
                for stmt in &block.stmts {
                    self.visit_stmt(stmt);
                }
            }
            Stmt::If(if_stmt) => {
                self.visit_expr(&if_stmt.test);
                self.visit_stmt(&if_stmt.cons);
                if let Some(alt) = &if_stmt.alt {
                    self.visit_stmt(alt);
                }
            }
            Stmt::Switch(switch) => {
                self.visit_expr(&switch.discriminant);
                for case in &switch.cases {
                    if let Some(test) = &case.test {
                        self.visit_expr(test);
                    }
                    for stmt in &case.cons {
                        self.visit_stmt(stmt);
                    }
                }
            }
            Stmt::For(for_stmt) => self.visit_stmt(&for_stmt.body),
            Stmt::ForIn(for_in) => self.visit_stmt(&for_in.body),
            Stmt::ForOf(for_of) => self.visit_stmt(&for_of.body),
            Stmt::While(while_stmt) => {
                self.visit_expr(&while_stmt.test);
                self.visit_stmt(&while_stmt.body);
            }
            Stmt::Try(try_stmt) => {
                for stmt in &try_stmt.block.stmts {
                    self.visit_stmt(stmt);
                }
                if let Some(handler) = &try_stmt.handler {
                    for stmt in &handler.body.stmts {
                        self.visit_stmt(stmt);
                    }
                }
                if let Some(finalizer) = &try_stmt.finalizer {
                    for stmt in &finalizer.stmts {
                        self.visit_stmt(stmt);
                    }
                }
            }
            _ => {}
        }
    }

    fn visit_decl(&mut self, decl: &Decl) {
        match decl {
            Decl::Var(var) => {
                for declarator in &var.decls {
                    if let Some(init) = &declarator.init {
                        self.visit_expr(init);
                    }
                }
            }
            Decl::Fn(fn_decl) => {
                if let Some(body) = &fn_decl.function.body {
                    for stmt in &body.stmts {
                        self.visit_stmt(stmt);
                    }
                }
            }
            _ => {}
        }
    }

    fn visit_expr(&mut self, expr: &Expr) {
        match expr {
            Expr::Call(call) => {
                self.check_call(call);
                for arg in &call.args {
                    self.visit_expr(&arg.expr);
                }
                if let Callee::Expr(callee) = &call.callee {
                    self.visit_expr(callee);
                }
            }
            Expr::Arrow(arrow) => match &*arrow.body {
                BlockStmtOrExpr::BlockStmt(block) => {
                    for stmt in &block.stmts {
                        self.visit_stmt(stmt);
                    }
                }
                BlockStmtOrExpr::Expr(expr) => self.visit_expr(expr),
            },
            Expr::Fn(fn_expr) => {
                if let Some(body) = &fn_expr.function.body {
                    for stmt in &body.stmts {
                        self.visit_stmt(stmt);
                    }
                }
            }
            Expr::Paren(paren) => self.visit_expr(&paren.expr),
            Expr::Bin(bin) => {
                self.visit_expr(&bin.left);
                self.visit_expr(&bin.right);
            }
            Expr::Cond(cond) => {
                self.visit_expr(&cond.test);
                self.visit_expr(&cond.cons);
                self.visit_expr(&cond.alt);
            }
            Expr::Assign(assign) => self.visit_expr(&assign.right),
            Expr::Array(arr) => {
                for elem in arr.elems.iter().flatten() {
                    self.visit_expr(&elem.expr);
                }
            }
            Expr::Object(obj) => {
                for prop in &obj.props {
                    match prop {
                        PropOrSpread::Prop(prop) => {
                            if let Prop::KeyValue(kv) = prop.as_ref() {
                                self.visit_expr(&kv.value);
                            }
                        }
                        PropOrSpread::Spread(spread) => self.visit_expr(&spread.expr),
                    }
                }
            }
            Expr::Tpl(tpl) => {
                for expr in &tpl.exprs {
                    self.visit_expr(expr);
                }
            }
            Expr::TaggedTpl(tagged) => {
                self.visit_expr(&tagged.tag);
                for expr in &tagged.tpl.exprs {
                    self.visit_expr(expr);
                }
            }
            Expr::Seq(seq) => {
                for expr in &seq.exprs {
                    self.visit_expr(expr);
                }
            }
            Expr::Member(member) => self.visit_expr(&member.obj),
            Expr::JSXElement(jsx) => self.visit_jsx_element(jsx),
            Expr::JSXFragment(jsx) => {
                for child in &jsx.children {
                    self.visit_jsx_child(child);
                }
            }
            Expr::Await(await_expr) => self.visit_expr(&await_expr.arg),
            Expr::Yield(yield_expr) => {
                if let Some(arg) = &yield_expr.arg {
                    self.visit_expr(arg);
                }
            }
            Expr::Unary(unary) => self.visit_expr(&unary.arg),
            Expr::TsAs(ts_as) => self.visit_expr(&ts_as.expr),
            Expr::TsSatisfies(ts_sat) => self.visit_expr(&ts_sat.expr),
            Expr::TsNonNull(ts_nn) => self.visit_expr(&ts_nn.expr),
            _ => {}
        }
    }

    fn visit_jsx_element(&mut self, jsx: &JSXElement) {
        for attr in &jsx.opening.attrs {
            if let JSXAttrOrSpread::JSXAttr(attr) = attr {
                if let Some(JSXAttrValue::JSXExprContainer(container)) = &attr.value {
                    if let JSXExpr::Expr(expr) = &container.expr {
                        self.visit_expr(expr);
                    }
                }
            }
        }
        for child in &jsx.children {
            self.visit_jsx_child(child);
        }
    }

    fn visit_jsx_child(&mut self, child: &JSXElementChild) {
        match child {
            JSXElementChild::JSXExprContainer(container) => {
                if let JSXExpr::Expr(expr) = &container.expr {
                    self.visit_expr(expr);
                }
            }
            JSXElementChild::JSXElement(element) => self.visit_jsx_element(element),
            JSXElementChild::JSXFragment(fragment) => {
                for child in &fragment.children {
                    self.visit_jsx_child(child);
                }
            }
            _ => {}
        }
    }

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

        if is_translation_hook(&func_name) {
            return;
        }
        if !is_member_t && !self.is_translation_call(&func_name, call) {
            return;
        }

        let Some(first_arg) = call.args.first() else {
            return;
        };

        let (lnum, col, end_col) = span_to_loc(self.cm, first_arg.expr.span());
        if let Some(range) = self.range {
            if lnum < range.start_line || lnum > range.end_line {
                return;
            }
        }

        let values = eval_string_exprs(&first_arg.expr, lnum, self.const_bindings);
        if values.is_empty() {
            return;
        }

        for value in values {
            let (key, namespace, fallback) = self.resolve_namespace(&value, lnum);
            self.items.push(ScanItem {
                key,
                raw: value,
                namespace,
                lnum,
                col,
                end_col,
                fallback,
            });
        }
    }

    fn is_translation_call(&self, func_name: &str, call: &CallExpr) -> bool {
        if func_name == "t" {
            return true;
        }
        let (lnum, _, _) = span_to_loc(self.cm, call.span);
        for scope in self.scopes {
            if lnum >= scope.start_line && lnum <= scope.end_line {
                if let Some(t_func) = &scope.t_func {
                    if t_func == func_name {
                        return true;
                    }
                }
            }
        }
        false
    }

    fn resolve_namespace(&self, value: &str, lnum: u32) -> (String, String, bool) {
        if let Some(colon_pos) = value.find(':') {
            let namespace = &value[..colon_pos];
            return (value.to_string(), namespace.to_string(), false);
        }

        for scope in self.scopes {
            if lnum >= scope.start_line && lnum <= scope.end_line {
                if let Some(namespace) = &scope.ns {
                    return (format!("{}:{}", namespace, value), namespace.clone(), false);
                }
            }
        }

        let namespace = self.fallback_namespace.to_string();
        (format!("{}:{}", namespace, value), namespace, true)
    }
}

#[cfg(test)]
mod tests {
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
}
