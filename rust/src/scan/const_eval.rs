use swc_common::{SourceMap, Spanned};
use swc_ecma_ast::*;

use super::parser::{span_to_lines, span_to_loc};

#[derive(Debug, Clone)]
pub(super) struct ConstBinding {
    pub(super) name: String,
    pub(super) value: String,
    pub(super) scope_start: u32,
    pub(super) scope_end: u32,
    pub(super) decl_line: u32,
    pub(super) order: usize,
}

fn wtf8_to_string(atom: &swc_atoms::Wtf8Atom) -> String {
    atom.as_wtf8().as_str().unwrap_or_default().to_string()
}

pub(super) fn resolve_const_at_line(
    name: &str,
    line: u32,
    const_bindings: &[ConstBinding],
) -> Option<String> {
    let mut best: Option<&ConstBinding> = None;

    for binding in const_bindings {
        if binding.name != name {
            continue;
        }
        if line < binding.scope_start || line > binding.scope_end {
            continue;
        }
        if binding.decl_line > line {
            continue;
        }

        let Some(current) = best else {
            best = Some(binding);
            continue;
        };

        let binding_scope_len = binding.scope_end.saturating_sub(binding.scope_start);
        let current_scope_len = current.scope_end.saturating_sub(current.scope_start);
        let better_scope = binding_scope_len < current_scope_len;
        let same_scope = binding_scope_len == current_scope_len;
        let better_line = binding.decl_line > current.decl_line;
        let same_line = binding.decl_line == current.decl_line;
        let better_order = binding.order > current.order;
        if better_scope || (same_scope && (better_line || (same_line && better_order))) {
            best = Some(binding);
        }
    }

    best.map(|binding| binding.value.clone())
}

fn eval_string_expr_with_resolver<F>(expr: &Expr, resolve_ident: &F) -> Option<String>
where
    F: Fn(&str) -> Option<String>,
{
    match expr {
        Expr::Lit(Lit::Str(s)) => Some(wtf8_to_string(&s.value)),
        Expr::Tpl(tpl) => {
            let mut result = String::new();
            for (i, quasi) in tpl.quasis.iter().enumerate() {
                result.push_str(&quasi.raw);
                if let Some(expr) = tpl.exprs.get(i) {
                    let value = eval_string_expr_with_resolver(expr, resolve_ident)?;
                    result.push_str(&value);
                }
            }
            Some(result)
        }
        Expr::Bin(bin) if bin.op == BinaryOp::Add => {
            let left = eval_string_expr_with_resolver(&bin.left, resolve_ident)?;
            let right = eval_string_expr_with_resolver(&bin.right, resolve_ident)?;
            Some(format!("{}{}", left, right))
        }
        Expr::Ident(ident) => resolve_ident(ident.sym.as_ref()),
        Expr::Paren(paren) => eval_string_expr_with_resolver(&paren.expr, resolve_ident),
        Expr::TsAs(ts_as) => eval_string_expr_with_resolver(&ts_as.expr, resolve_ident),
        Expr::TsSatisfies(ts_sat) => eval_string_expr_with_resolver(&ts_sat.expr, resolve_ident),
        Expr::TsNonNull(ts_nn) => eval_string_expr_with_resolver(&ts_nn.expr, resolve_ident),
        Expr::TsConstAssertion(ts_const) => {
            eval_string_expr_with_resolver(&ts_const.expr, resolve_ident)
        }
        _ => None,
    }
}

pub(super) fn eval_string_expr(
    expr: &Expr,
    line: u32,
    const_bindings: &[ConstBinding],
) -> Option<String> {
    eval_string_expr_with_resolver(expr, &|name| {
        resolve_const_at_line(name, line, const_bindings)
    })
}

fn eval_string_exprs_multi<F>(expr: &Expr, resolve_ident: &F) -> Vec<String>
where
    F: Fn(&str) -> Option<String>,
{
    match expr {
        Expr::Cond(cond) => {
            let mut results = eval_string_exprs_multi(&cond.cons, resolve_ident);
            results.extend(eval_string_exprs_multi(&cond.alt, resolve_ident));
            results
        }
        Expr::Bin(bin) if bin.op == BinaryOp::Add => {
            let lefts = eval_string_exprs_multi(&bin.left, resolve_ident);
            let rights = eval_string_exprs_multi(&bin.right, resolve_ident);
            if lefts.is_empty() || rights.is_empty() {
                return Vec::new();
            }
            let mut results = Vec::with_capacity(lefts.len() * rights.len());
            for left in &lefts {
                for right in &rights {
                    results.push(format!("{}{}", left, right));
                }
            }
            results
        }
        Expr::Tpl(tpl) => {
            let mut accum: Vec<String> = Vec::new();
            for (i, quasi) in tpl.quasis.iter().enumerate() {
                let quasi_str: &str = &quasi.raw;
                if accum.is_empty() {
                    accum.push(quasi_str.to_string());
                } else {
                    for value in &mut accum {
                        value.push_str(quasi_str);
                    }
                }
                if let Some(expr) = tpl.exprs.get(i) {
                    let values = eval_string_exprs_multi(expr, resolve_ident);
                    if values.is_empty() {
                        return Vec::new();
                    }
                    let mut next = Vec::with_capacity(accum.len() * values.len());
                    for prefix in &accum {
                        for value in &values {
                            next.push(format!("{}{}", prefix, value));
                        }
                    }
                    accum = next;
                }
            }
            accum
        }
        Expr::Paren(paren) => eval_string_exprs_multi(&paren.expr, resolve_ident),
        Expr::TsAs(ts_as) => eval_string_exprs_multi(&ts_as.expr, resolve_ident),
        Expr::TsSatisfies(ts_sat) => eval_string_exprs_multi(&ts_sat.expr, resolve_ident),
        Expr::TsNonNull(ts_nn) => eval_string_exprs_multi(&ts_nn.expr, resolve_ident),
        Expr::TsConstAssertion(ts_const) => eval_string_exprs_multi(&ts_const.expr, resolve_ident),
        _ => eval_string_expr_with_resolver(expr, resolve_ident)
            .into_iter()
            .collect(),
    }
}

pub(super) fn eval_string_exprs(
    expr: &Expr,
    line: u32,
    const_bindings: &[ConstBinding],
) -> Vec<String> {
    eval_string_exprs_multi(expr, &|name| {
        resolve_const_at_line(name, line, const_bindings)
    })
}

pub(super) fn collect_consts(module: &Module, cm: &SourceMap) -> Vec<ConstBinding> {
    struct ConstCollector<'a> {
        cm: &'a SourceMap,
        const_bindings: Vec<ConstBinding>,
        next_order: usize,
    }

    impl<'a> ConstCollector<'a> {
        fn new(cm: &'a SourceMap) -> Self {
            Self {
                cm,
                const_bindings: Vec::new(),
                next_order: 0,
            }
        }

        fn visit_module(&mut self, module: &Module) {
            let (module_start, module_end) = span_to_lines(self.cm, module.span);
            for item in &module.body {
                self.visit_module_item(item, module_start, module_end);
            }
        }

        fn visit_module_item(&mut self, item: &ModuleItem, scope_start: u32, scope_end: u32) {
            match item {
                ModuleItem::Stmt(stmt) => self.visit_stmt(stmt, scope_start, scope_end),
                ModuleItem::ModuleDecl(decl) => {
                    self.visit_module_decl(decl, scope_start, scope_end)
                }
            }
        }

        fn visit_module_decl(&mut self, decl: &ModuleDecl, scope_start: u32, scope_end: u32) {
            match decl {
                ModuleDecl::ExportDecl(export) => {
                    self.visit_decl(&export.decl, scope_start, scope_end)
                }
                ModuleDecl::ExportDefaultExpr(export) => {
                    self.visit_expr(&export.expr, scope_start, scope_end)
                }
                ModuleDecl::ExportDefaultDecl(export) => {
                    if let DefaultDecl::Fn(fn_expr) = &export.decl {
                        if let Some(body) = &fn_expr.function.body {
                            let (body_start, body_end) = span_to_lines(self.cm, body.span);
                            for stmt in &body.stmts {
                                self.visit_stmt(stmt, body_start, body_end);
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        fn visit_stmt(&mut self, stmt: &Stmt, scope_start: u32, scope_end: u32) {
            match stmt {
                Stmt::Decl(decl) => self.visit_decl(decl, scope_start, scope_end),
                Stmt::Expr(expr_stmt) => self.visit_expr(&expr_stmt.expr, scope_start, scope_end),
                Stmt::Return(ret) => {
                    if let Some(arg) = &ret.arg {
                        self.visit_expr(arg, scope_start, scope_end);
                    }
                }
                Stmt::Block(block) => {
                    let (block_start, block_end) = span_to_lines(self.cm, block.span);
                    for stmt in &block.stmts {
                        self.visit_stmt(stmt, block_start, block_end);
                    }
                }
                Stmt::If(if_stmt) => {
                    self.visit_expr(&if_stmt.test, scope_start, scope_end);
                    self.visit_stmt(&if_stmt.cons, scope_start, scope_end);
                    if let Some(alt) = &if_stmt.alt {
                        self.visit_stmt(alt, scope_start, scope_end);
                    }
                }
                Stmt::Switch(switch) => {
                    self.visit_expr(&switch.discriminant, scope_start, scope_end);
                    for case in &switch.cases {
                        if let Some(test) = &case.test {
                            self.visit_expr(test, scope_start, scope_end);
                        }
                        for stmt in &case.cons {
                            self.visit_stmt(stmt, scope_start, scope_end);
                        }
                    }
                }
                Stmt::For(for_stmt) => {
                    let (loop_start, loop_end) = span_to_lines(self.cm, for_stmt.span);
                    if let Some(init) = &for_stmt.init {
                        match init {
                            VarDeclOrExpr::VarDecl(var_decl) => {
                                self.collect_var_decl(var_decl, loop_start, loop_end)
                            }
                            VarDeclOrExpr::Expr(expr) => {
                                self.visit_expr(expr, loop_start, loop_end)
                            }
                        }
                    }
                    if let Some(test) = &for_stmt.test {
                        self.visit_expr(test, loop_start, loop_end);
                    }
                    if let Some(update) = &for_stmt.update {
                        self.visit_expr(update, loop_start, loop_end);
                    }
                    self.visit_stmt(&for_stmt.body, loop_start, loop_end);
                }
                Stmt::ForIn(for_in) => {
                    let (loop_start, loop_end) = span_to_lines(self.cm, for_in.span);
                    if let ForHead::VarDecl(var_decl) = &for_in.left {
                        self.collect_var_decl(var_decl, loop_start, loop_end);
                    }
                    self.visit_expr(&for_in.right, loop_start, loop_end);
                    self.visit_stmt(&for_in.body, loop_start, loop_end);
                }
                Stmt::ForOf(for_of) => {
                    let (loop_start, loop_end) = span_to_lines(self.cm, for_of.span);
                    if let ForHead::VarDecl(var_decl) = &for_of.left {
                        self.collect_var_decl(var_decl, loop_start, loop_end);
                    }
                    self.visit_expr(&for_of.right, loop_start, loop_end);
                    self.visit_stmt(&for_of.body, loop_start, loop_end);
                }
                Stmt::While(while_stmt) => {
                    self.visit_expr(&while_stmt.test, scope_start, scope_end);
                    self.visit_stmt(&while_stmt.body, scope_start, scope_end);
                }
                Stmt::DoWhile(do_while) => {
                    self.visit_stmt(&do_while.body, scope_start, scope_end);
                    self.visit_expr(&do_while.test, scope_start, scope_end);
                }
                Stmt::Try(try_stmt) => {
                    for stmt in &try_stmt.block.stmts {
                        self.visit_stmt(stmt, scope_start, scope_end);
                    }
                    if let Some(handler) = &try_stmt.handler {
                        let (handler_start, handler_end) =
                            span_to_lines(self.cm, handler.body.span);
                        for stmt in &handler.body.stmts {
                            self.visit_stmt(stmt, handler_start, handler_end);
                        }
                    }
                    if let Some(finalizer) = &try_stmt.finalizer {
                        let (finalizer_start, finalizer_end) =
                            span_to_lines(self.cm, finalizer.span);
                        for stmt in &finalizer.stmts {
                            self.visit_stmt(stmt, finalizer_start, finalizer_end);
                        }
                    }
                }
                _ => {}
            }
        }

        fn visit_decl(&mut self, decl: &Decl, scope_start: u32, scope_end: u32) {
            match decl {
                Decl::Var(var_decl) => self.collect_var_decl(var_decl, scope_start, scope_end),
                Decl::Fn(fn_decl) => {
                    if let Some(body) = &fn_decl.function.body {
                        let (body_start, body_end) = span_to_lines(self.cm, body.span);
                        for stmt in &body.stmts {
                            self.visit_stmt(stmt, body_start, body_end);
                        }
                    }
                }
                _ => {}
            }
        }

        fn collect_var_decl(&mut self, var_decl: &VarDecl, scope_start: u32, scope_end: u32) {
            if var_decl.kind == VarDeclKind::Const {
                for decl in &var_decl.decls {
                    if let Pat::Ident(ident) = &decl.name {
                        if let Some(init) = &decl.init {
                            let (decl_line, _, _) = span_to_loc(self.cm, decl.span());
                            if let Some(value) = eval_string_expr_with_resolver(init, &|name| {
                                resolve_const_at_line(name, decl_line, &self.const_bindings)
                            }) {
                                self.const_bindings.push(ConstBinding {
                                    name: ident.sym.to_string(),
                                    value,
                                    scope_start,
                                    scope_end,
                                    decl_line,
                                    order: self.next_order,
                                });
                                self.next_order += 1;
                            }
                        }
                    }
                    if let Some(init) = &decl.init {
                        self.visit_expr(init, scope_start, scope_end);
                    }
                }
                return;
            }

            for decl in &var_decl.decls {
                if let Some(init) = &decl.init {
                    self.visit_expr(init, scope_start, scope_end);
                }
            }
        }

        fn visit_expr(&mut self, expr: &Expr, _scope_start: u32, _scope_end: u32) {
            match expr {
                Expr::Call(call) => {
                    for arg in &call.args {
                        self.visit_expr(&arg.expr, _scope_start, _scope_end);
                    }
                    if let Callee::Expr(callee) = &call.callee {
                        self.visit_expr(callee, _scope_start, _scope_end);
                    }
                }
                Expr::Arrow(arrow) => match &*arrow.body {
                    BlockStmtOrExpr::BlockStmt(block) => {
                        let (block_start, block_end) = span_to_lines(self.cm, block.span);
                        for stmt in &block.stmts {
                            self.visit_stmt(stmt, block_start, block_end);
                        }
                    }
                    BlockStmtOrExpr::Expr(expr) => {
                        let (arrow_start, arrow_end) = span_to_lines(self.cm, arrow.span);
                        self.visit_expr(expr, arrow_start, arrow_end);
                    }
                },
                Expr::Fn(fn_expr) => {
                    if let Some(body) = &fn_expr.function.body {
                        let (body_start, body_end) = span_to_lines(self.cm, body.span);
                        for stmt in &body.stmts {
                            self.visit_stmt(stmt, body_start, body_end);
                        }
                    }
                }
                Expr::Paren(paren) => self.visit_expr(&paren.expr, _scope_start, _scope_end),
                Expr::Bin(bin) => {
                    self.visit_expr(&bin.left, _scope_start, _scope_end);
                    self.visit_expr(&bin.right, _scope_start, _scope_end);
                }
                Expr::Cond(cond) => {
                    self.visit_expr(&cond.test, _scope_start, _scope_end);
                    self.visit_expr(&cond.cons, _scope_start, _scope_end);
                    self.visit_expr(&cond.alt, _scope_start, _scope_end);
                }
                Expr::Assign(assign) => self.visit_expr(&assign.right, _scope_start, _scope_end),
                Expr::Array(arr) => {
                    for elem in arr.elems.iter().flatten() {
                        self.visit_expr(&elem.expr, _scope_start, _scope_end);
                    }
                }
                Expr::Object(obj) => {
                    for prop in &obj.props {
                        match prop {
                            PropOrSpread::Prop(prop) => {
                                if let Prop::KeyValue(kv) = prop.as_ref() {
                                    self.visit_expr(&kv.value, _scope_start, _scope_end);
                                }
                            }
                            PropOrSpread::Spread(spread) => {
                                self.visit_expr(&spread.expr, _scope_start, _scope_end);
                            }
                        }
                    }
                }
                Expr::Tpl(tpl) => {
                    for expr in &tpl.exprs {
                        self.visit_expr(expr, _scope_start, _scope_end);
                    }
                }
                Expr::TaggedTpl(tagged) => {
                    self.visit_expr(&tagged.tag, _scope_start, _scope_end);
                    for expr in &tagged.tpl.exprs {
                        self.visit_expr(expr, _scope_start, _scope_end);
                    }
                }
                Expr::Seq(seq) => {
                    for expr in &seq.exprs {
                        self.visit_expr(expr, _scope_start, _scope_end);
                    }
                }
                Expr::Member(member) => {
                    self.visit_expr(&member.obj, _scope_start, _scope_end);
                    if let MemberProp::Computed(computed) = &member.prop {
                        self.visit_expr(&computed.expr, _scope_start, _scope_end);
                    }
                }
                Expr::Await(await_expr) => {
                    self.visit_expr(&await_expr.arg, _scope_start, _scope_end)
                }
                Expr::Yield(yield_expr) => {
                    if let Some(arg) = &yield_expr.arg {
                        self.visit_expr(arg, _scope_start, _scope_end);
                    }
                }
                Expr::Unary(unary) => self.visit_expr(&unary.arg, _scope_start, _scope_end),
                Expr::TsAs(ts_as) => self.visit_expr(&ts_as.expr, _scope_start, _scope_end),
                Expr::TsSatisfies(ts_sat) => {
                    self.visit_expr(&ts_sat.expr, _scope_start, _scope_end)
                }
                Expr::TsNonNull(ts_nn) => self.visit_expr(&ts_nn.expr, _scope_start, _scope_end),
                _ => {}
            }
        }
    }

    let mut collector = ConstCollector::new(cm);
    collector.visit_module(module);
    collector.const_bindings
}

#[cfg(test)]
mod tests;
