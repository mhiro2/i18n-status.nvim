use swc_common::SourceMap;
use swc_ecma_ast::*;

use super::const_eval::{ConstBinding, eval_string_expr};
use super::parser::{span_to_lines, span_to_loc};

#[derive(Debug, Clone)]
pub(super) struct NamespaceScope {
    pub(super) ns: Option<String>,
    pub(super) t_func: Option<String>,
    pub(super) start_line: u32,
    pub(super) end_line: u32,
}

pub(super) fn is_translation_hook(name: &str) -> bool {
    matches!(
        name,
        "useTranslation" | "useTranslations" | "getTranslations"
    )
}

fn get_callee_name(callee: &Callee) -> Option<String> {
    match callee {
        Callee::Expr(expr) => match expr.as_ref() {
            Expr::Ident(ident) => Some(ident.sym.to_string()),
            _ => None,
        },
        _ => None,
    }
}

fn get_first_string_arg(
    args: &[ExprOrSpread],
    line: u32,
    const_bindings: &[ConstBinding],
) -> Option<String> {
    args.first()
        .and_then(|arg| eval_string_expr(&arg.expr, line, const_bindings))
}

fn extract_hook_call(expr: &Expr) -> Option<&CallExpr> {
    match expr {
        Expr::Call(call) => Some(call),
        Expr::Await(await_expr) => extract_hook_call(&await_expr.arg),
        Expr::Paren(paren) => extract_hook_call(&paren.expr),
        Expr::TsAs(ts_as) => extract_hook_call(&ts_as.expr),
        Expr::TsSatisfies(ts_sat) => extract_hook_call(&ts_sat.expr),
        Expr::TsNonNull(ts_nn) => extract_hook_call(&ts_nn.expr),
        _ => None,
    }
}

fn detect_t_func_name(name: &Pat) -> Option<String> {
    match name {
        Pat::Ident(ident) => Some(ident.sym.to_string()),
        Pat::Object(obj) => {
            for prop in &obj.props {
                match prop {
                    ObjectPatProp::Assign(assign) if assign.key.sym.as_ref() == "t" => {
                        return Some("t".to_string());
                    }
                    ObjectPatProp::KeyValue(kv) => {
                        if let PropName::Ident(key) = &kv.key {
                            if key.sym.as_ref() == "t" {
                                if let Pat::Ident(value) = &*kv.value {
                                    return Some(value.sym.to_string());
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
            None
        }
        Pat::Array(arr) => arr.elems.first().and_then(|elem| {
            elem.as_ref().and_then(|pat| match pat {
                Pat::Ident(ident) => Some(ident.sym.to_string()),
                _ => None,
            })
        }),
        _ => None,
    }
}

pub(super) fn collect_scopes_precise(
    module: &Module,
    cm: &SourceMap,
    const_bindings: &[ConstBinding],
) -> Vec<NamespaceScope> {
    let mut collector = ScopeCollector {
        cm,
        const_bindings,
        scopes: Vec::new(),
    };
    for item in &module.body {
        collector.visit_module_item(item, 0, u32::MAX);
    }
    collector
        .scopes
        .sort_by_key(|scope| scope.end_line - scope.start_line);
    collector.scopes
}

struct ScopeCollector<'a> {
    cm: &'a SourceMap,
    const_bindings: &'a [ConstBinding],
    scopes: Vec<NamespaceScope>,
}

impl<'a> ScopeCollector<'a> {
    fn visit_module_item(&mut self, item: &ModuleItem, scope_start: u32, scope_end: u32) {
        match item {
            ModuleItem::Stmt(stmt) => self.visit_stmt(stmt, scope_start, scope_end),
            ModuleItem::ModuleDecl(decl) => match decl {
                ModuleDecl::ExportDecl(export) => {
                    self.visit_decl(&export.decl, scope_start, scope_end);
                }
                ModuleDecl::ExportDefaultExpr(export) => {
                    self.visit_expr(&export.expr, scope_start, scope_end);
                }
                ModuleDecl::ExportDefaultDecl(export) => {
                    if let DefaultDecl::Fn(fn_expr) = &export.decl {
                        if let Some(body) = &fn_expr.function.body {
                            let (start, end) = span_to_lines(self.cm, body.span);
                            for stmt in &body.stmts {
                                self.visit_stmt(stmt, start, end);
                            }
                        }
                    }
                }
                _ => {}
            },
        }
    }

    fn visit_stmt(&mut self, stmt: &Stmt, scope_start: u32, scope_end: u32) {
        match stmt {
            Stmt::Decl(decl) => self.visit_decl(decl, scope_start, scope_end),
            Stmt::Expr(expr_stmt) => {
                if let Some(call) = extract_hook_call(expr_stmt.expr.as_ref()) {
                    if let Some(name) = get_callee_name(&call.callee) {
                        if is_translation_hook(&name) {
                            let (call_line, _, _) = span_to_loc(self.cm, call.span);
                            let ns =
                                get_first_string_arg(&call.args, call_line, self.const_bindings);
                            self.scopes.push(NamespaceScope {
                                ns,
                                t_func: Some("t".to_string()),
                                start_line: scope_start,
                                end_line: scope_end,
                            });
                        }
                    }
                }
                self.visit_expr(&expr_stmt.expr, scope_start, scope_end);
            }
            Stmt::Return(ret) => {
                if let Some(arg) = &ret.arg {
                    self.visit_expr(arg, scope_start, scope_end);
                }
            }
            Stmt::Block(block) => {
                for stmt in &block.stmts {
                    self.visit_stmt(stmt, scope_start, scope_end);
                }
            }
            Stmt::If(if_stmt) => {
                self.visit_stmt(&if_stmt.cons, scope_start, scope_end);
                if let Some(alt) = &if_stmt.alt {
                    self.visit_stmt(alt, scope_start, scope_end);
                }
            }
            _ => {}
        }
    }

    fn visit_decl(&mut self, decl: &Decl, scope_start: u32, scope_end: u32) {
        match decl {
            Decl::Var(var) => {
                for declarator in &var.decls {
                    if let Some(init) = &declarator.init {
                        if let Some(call) = extract_hook_call(init.as_ref()) {
                            if let Some(name) = get_callee_name(&call.callee) {
                                if is_translation_hook(&name) {
                                    let (call_line, _, _) = span_to_loc(self.cm, call.span);
                                    let ns = get_first_string_arg(
                                        &call.args,
                                        call_line,
                                        self.const_bindings,
                                    );
                                    let t_func = detect_t_func_name(&declarator.name);
                                    self.scopes.push(NamespaceScope {
                                        ns,
                                        t_func,
                                        start_line: scope_start,
                                        end_line: scope_end,
                                    });
                                }
                            }
                        }
                        self.visit_expr(init, scope_start, scope_end);
                    }
                }
            }
            Decl::Fn(fn_decl) => {
                if let Some(body) = &fn_decl.function.body {
                    let (start, end) = span_to_lines(self.cm, body.span);
                    for stmt in &body.stmts {
                        self.visit_stmt(stmt, start, end);
                    }
                }
            }
            _ => {}
        }
    }

    fn visit_expr(&mut self, expr: &Expr, _scope_start: u32, _scope_end: u32) {
        match expr {
            Expr::Arrow(arrow) => match &*arrow.body {
                BlockStmtOrExpr::BlockStmt(block) => {
                    let (start, end) = span_to_lines(self.cm, block.span);
                    for stmt in &block.stmts {
                        self.visit_stmt(stmt, start, end);
                    }
                }
                BlockStmtOrExpr::Expr(expr) => {
                    let (start, end) = span_to_lines(self.cm, arrow.span);
                    self.visit_expr(expr, start, end);
                }
            },
            Expr::Fn(fn_expr) => {
                if let Some(body) = &fn_expr.function.body {
                    let (start, end) = span_to_lines(self.cm, body.span);
                    for stmt in &body.stmts {
                        self.visit_stmt(stmt, start, end);
                    }
                }
            }
            Expr::Call(call) => {
                for arg in &call.args {
                    self.visit_expr(&arg.expr, _scope_start, _scope_end);
                }
            }
            Expr::Paren(paren) => self.visit_expr(&paren.expr, _scope_start, _scope_end),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::const_eval::collect_consts;
    use crate::scan::parser::parse_module;

    fn collect_scopes(source: &str) -> Vec<NamespaceScope> {
        let (module, cm) = parse_module(source, "tsx").expect("source should parse");
        let const_bindings = collect_consts(&module, &cm);
        collect_scopes_precise(&module, &cm, &const_bindings)
    }

    #[test]
    fn collects_alias_from_destructured_hook_binding() {
        let scopes = collect_scopes(
            r#"
function Page() {
  const { t: tt } = useTranslation("dashboard");
  return tt("title");
}
"#,
        );

        assert_eq!(scopes.len(), 1);
        assert_eq!(scopes[0].ns.as_deref(), Some("dashboard"));
        assert_eq!(scopes[0].t_func.as_deref(), Some("tt"));
    }

    #[test]
    fn registers_default_t_for_bare_hook_call() {
        let scopes = collect_scopes(
            r#"
function Page() {
  useTranslation("home");
  return t("title");
}
"#,
        );

        assert_eq!(scopes.len(), 1);
        assert_eq!(scopes[0].ns.as_deref(), Some("home"));
        assert_eq!(scopes[0].t_func.as_deref(), Some("t"));
    }
}
