use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use swc_common::{FileName, SourceMap, Spanned, input::SourceFileInput, sync::Lrc};
use swc_ecma_ast::*;
use swc_ecma_parser::{EsSyntax, Parser, Syntax, TsSyntax, lexer::Lexer};

/// Convert a Wtf8Atom (string literal value) to a Rust String
fn wtf8_to_string(atom: &swc_atoms::Wtf8Atom) -> String {
    atom.as_wtf8().as_str().unwrap_or_default().to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanItem {
    pub key: String,
    pub raw: String,
    pub namespace: String,
    pub lnum: u32,
    pub col: u32,
    pub end_col: u32,
    pub fallback: bool,
}

#[derive(Debug, Deserialize)]
pub struct ExtractParams {
    pub source: String,
    pub lang: String,
    pub fallback_namespace: String,
    pub range: Option<Range>,
}

#[derive(Debug, Deserialize)]
pub struct ExtractResourceParams {
    pub source: String,
    pub namespace: String,
    pub is_root: bool,
    pub range: Option<Range>,
}

#[derive(Debug, Deserialize)]
pub struct TranslationContextParams {
    pub source: String,
    pub lang: String,
    pub row: u32,
    pub fallback_namespace: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Range {
    pub start_line: u32,
    pub end_line: u32,
}

#[derive(Debug, Serialize)]
pub struct TranslationContext {
    pub namespace: String,
    pub t_func: String,
    pub found_hook: bool,
    pub has_any_hook: bool,
}

/// A namespace scope from useTranslation/useTranslations/getTranslations
#[derive(Debug, Clone)]
struct NamespaceScope {
    ns: Option<String>,
    t_func: Option<String>,
    start_line: u32,
    end_line: u32,
}

/// Parse source code into a Module using swc
fn parse_module(source: &str, lang: &str) -> Result<(Module, Lrc<SourceMap>)> {
    let cm: Lrc<SourceMap> = Default::default();
    let fm = cm.new_source_file(
        Lrc::new(FileName::Custom("input".into())),
        source.to_string(),
    );

    let syntax = match lang {
        "tsx" => Syntax::Typescript(TsSyntax {
            tsx: true,
            ..Default::default()
        }),
        "typescript" => Syntax::Typescript(TsSyntax {
            tsx: false,
            ..Default::default()
        }),
        "jsx" => Syntax::Es(EsSyntax {
            jsx: true,
            ..Default::default()
        }),
        _ => Syntax::Es(EsSyntax {
            jsx: true,
            ..Default::default()
        }),
    };

    let lexer = Lexer::new(
        syntax,
        Default::default(),
        SourceFileInput::from(&*fm),
        None,
    );

    let mut parser = Parser::new_from(lexer);
    let module = parser
        .parse_module()
        .map_err(|e| anyhow::anyhow!("parse error: {:?}", e.into_kind().msg()))?;

    Ok((module, cm))
}

/// Get 0-indexed line/col from a swc Span
fn span_to_loc(cm: &SourceMap, span: swc_common::Span) -> (u32, u32, u32) {
    let lo = cm.lookup_char_pos(span.lo);
    let hi = cm.lookup_char_pos(span.hi);
    (
        lo.line as u32 - 1,
        lo.col_display as u32,
        hi.col_display as u32,
    )
}

/// Collect const declarations: `const KEY = "value"`
fn collect_consts(module: &Module) -> HashMap<String, String> {
    struct ConstCollector {
        consts: HashMap<String, String>,
    }

    impl ConstCollector {
        fn new() -> Self {
            Self {
                consts: HashMap::new(),
            }
        }

        fn visit_module(&mut self, module: &Module) {
            for item in &module.body {
                self.visit_module_item(item);
            }
        }

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
                Stmt::Decl(decl) => self.visit_decl(decl),
                Stmt::Expr(expr_stmt) => self.visit_expr(&expr_stmt.expr),
                Stmt::Return(ret) => {
                    if let Some(arg) = &ret.arg {
                        self.visit_expr(arg);
                    }
                }
                Stmt::Block(block) => {
                    for s in &block.stmts {
                        self.visit_stmt(s);
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
                        for s in &case.cons {
                            self.visit_stmt(s);
                        }
                    }
                }
                Stmt::For(for_stmt) => {
                    if let Some(init) = &for_stmt.init {
                        match init {
                            VarDeclOrExpr::VarDecl(var_decl) => self.collect_var_decl(var_decl),
                            VarDeclOrExpr::Expr(expr) => self.visit_expr(expr),
                        }
                    }
                    if let Some(test) = &for_stmt.test {
                        self.visit_expr(test);
                    }
                    if let Some(update) = &for_stmt.update {
                        self.visit_expr(update);
                    }
                    self.visit_stmt(&for_stmt.body);
                }
                Stmt::ForIn(for_in) => {
                    if let ForHead::VarDecl(var_decl) = &for_in.left {
                        self.collect_var_decl(var_decl);
                    }
                    self.visit_expr(&for_in.right);
                    self.visit_stmt(&for_in.body);
                }
                Stmt::ForOf(for_of) => {
                    if let ForHead::VarDecl(var_decl) = &for_of.left {
                        self.collect_var_decl(var_decl);
                    }
                    self.visit_expr(&for_of.right);
                    self.visit_stmt(&for_of.body);
                }
                Stmt::While(while_stmt) => {
                    self.visit_expr(&while_stmt.test);
                    self.visit_stmt(&while_stmt.body);
                }
                Stmt::DoWhile(do_while) => {
                    self.visit_stmt(&do_while.body);
                    self.visit_expr(&do_while.test);
                }
                Stmt::Try(try_stmt) => {
                    for s in &try_stmt.block.stmts {
                        self.visit_stmt(s);
                    }
                    if let Some(handler) = &try_stmt.handler {
                        for s in &handler.body.stmts {
                            self.visit_stmt(s);
                        }
                    }
                    if let Some(finalizer) = &try_stmt.finalizer {
                        for s in &finalizer.stmts {
                            self.visit_stmt(s);
                        }
                    }
                }
                _ => {}
            }
        }

        fn visit_decl(&mut self, decl: &Decl) {
            match decl {
                Decl::Var(var_decl) => self.collect_var_decl(var_decl),
                Decl::Fn(fn_decl) => {
                    if let Some(body) = &fn_decl.function.body {
                        for s in &body.stmts {
                            self.visit_stmt(s);
                        }
                    }
                }
                _ => {}
            }
        }

        fn collect_var_decl(&mut self, var_decl: &VarDecl) {
            if var_decl.kind == VarDeclKind::Const {
                for decl in &var_decl.decls {
                    if let Pat::Ident(ident) = &decl.name {
                        if let Some(init) = &decl.init {
                            if let Some(val) = eval_string_expr(init, &self.consts) {
                                self.consts.insert(ident.sym.to_string(), val);
                            }
                        }
                    }
                }
            }

            for decl in &var_decl.decls {
                if let Some(init) = &decl.init {
                    self.visit_expr(init);
                }
            }
        }

        fn visit_expr(&mut self, expr: &Expr) {
            match expr {
                Expr::Call(call) => {
                    for arg in &call.args {
                        self.visit_expr(&arg.expr);
                    }
                    if let Callee::Expr(callee) = &call.callee {
                        self.visit_expr(callee);
                    }
                }
                Expr::Arrow(arrow) => match &*arrow.body {
                    BlockStmtOrExpr::BlockStmt(block) => {
                        for s in &block.stmts {
                            self.visit_stmt(s);
                        }
                    }
                    BlockStmtOrExpr::Expr(e) => self.visit_expr(e),
                },
                Expr::Fn(fn_expr) => {
                    if let Some(body) = &fn_expr.function.body {
                        for s in &body.stmts {
                            self.visit_stmt(s);
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
                Expr::Assign(assign) => {
                    self.visit_expr(&assign.right);
                }
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
                            PropOrSpread::Spread(spread) => {
                                self.visit_expr(&spread.expr);
                            }
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
                Expr::Member(member) => {
                    self.visit_expr(&member.obj);
                    if let MemberProp::Computed(computed) = &member.prop {
                        self.visit_expr(&computed.expr);
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
    }

    let mut collector = ConstCollector::new();
    collector.visit_module(module);
    collector.consts
}

/// Evaluate a string expression (string literal, template literal, binary concat, const ref)
fn eval_string_expr(expr: &Expr, consts: &HashMap<String, String>) -> Option<String> {
    match expr {
        Expr::Lit(Lit::Str(s)) => Some(wtf8_to_string(&s.value)),
        Expr::Tpl(tpl) => {
            // Only static templates (no expressions)
            if !tpl.exprs.is_empty() {
                return None;
            }
            let mut result = String::new();
            for quasi in &tpl.quasis {
                result.push_str(&quasi.raw);
            }
            Some(result)
        }
        Expr::Bin(bin) => {
            if bin.op == BinaryOp::Add {
                let left = eval_string_expr(&bin.left, consts)?;
                let right = eval_string_expr(&bin.right, consts)?;
                Some(format!("{}{}", left, right))
            } else {
                None
            }
        }
        Expr::Ident(ident) => consts.get(&ident.sym.to_string()).cloned(),
        Expr::Paren(paren) => eval_string_expr(&paren.expr, consts),
        _ => None,
    }
}

/// Check if a function name is one of the translation hooks
fn is_translation_hook(name: &str) -> bool {
    matches!(
        name,
        "useTranslation" | "useTranslations" | "getTranslations"
    )
}

/// Get the function name from an expression (identifier or member expression)
fn get_callee_name(callee: &Callee) -> Option<String> {
    match callee {
        Callee::Expr(expr) => match expr.as_ref() {
            Expr::Ident(ident) => Some(ident.sym.to_string()),
            _ => None,
        },
        _ => None,
    }
}

/// Get the first string argument from a call expression
fn get_first_string_arg(args: &[ExprOrSpread], consts: &HashMap<String, String>) -> Option<String> {
    args.first()
        .and_then(|arg| eval_string_expr(&arg.expr, consts))
}

/// Unwrap wrappers around a hook call (e.g. await/paren/ts casts) and return the call expression.
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

/// Detect translation function binding name from a variable declarator
/// Handles: `const { t } = useTranslation()`, `const { t: alias } = ...`, `const t = useTranslations()`
fn detect_t_func_name(name: &Pat) -> Option<String> {
    match name {
        Pat::Ident(ident) => Some(ident.sym.to_string()),
        Pat::Object(obj) => {
            for prop in &obj.props {
                match prop {
                    ObjectPatProp::Assign(assign) => {
                        if assign.key.sym.as_ref() == "t" {
                            return Some("t".to_string());
                        }
                    }
                    ObjectPatProp::KeyValue(kv) => {
                        // { t: alias }
                        if let PropName::Ident(key) = &kv.key {
                            if key.sym.as_ref() == "t" {
                                if let Pat::Ident(val) = &*kv.value {
                                    return Some(val.sym.to_string());
                                }
                            }
                        }
                    }
                    ObjectPatProp::Rest(_) => {}
                }
            }
            // Check for { t } destructuring without rename
            for prop in &obj.props {
                if let ObjectPatProp::Assign(assign) = prop {
                    if assign.key.sym.as_ref() == "t" {
                        return Some("t".to_string());
                    }
                }
            }
            None
        }
        Pat::Array(arr) => {
            // Array destructuring: [t, ...]
            arr.elems.first().and_then(|elem| {
                elem.as_ref().and_then(|pat| {
                    if let Pat::Ident(ident) = pat {
                        Some(ident.sym.to_string())
                    } else {
                        None
                    }
                })
            })
        }
        _ => None,
    }
}

/// Main extraction: walk the AST and find all t() calls
fn extract_calls(
    module: &Module,
    cm: &SourceMap,
    consts: &HashMap<String, String>,
    scopes: &[NamespaceScope],
    fallback_namespace: &str,
    range: &Option<Range>,
) -> Vec<ScanItem> {
    let mut items = Vec::new();
    let mut visitor = CallVisitor {
        cm,
        consts,
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
    consts: &'a HashMap<String, String>,
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
            ModuleDecl::ExportDecl(export) => {
                self.visit_decl(&export.decl);
            }
            ModuleDecl::ExportDefaultExpr(export) => {
                self.visit_expr(&export.expr);
            }
            ModuleDecl::ExportDefaultDecl(export) => {
                if let DefaultDecl::Fn(fn_expr) = &export.decl {
                    if let Some(body) = &fn_expr.function.body {
                        for s in &body.stmts {
                            self.visit_stmt(s);
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
                for s in &block.stmts {
                    self.visit_stmt(s);
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
                    for s in &case.cons {
                        self.visit_stmt(s);
                    }
                }
            }
            Stmt::For(for_stmt) => {
                self.visit_stmt(&for_stmt.body);
            }
            Stmt::ForIn(for_in) => {
                self.visit_stmt(&for_in.body);
            }
            Stmt::ForOf(for_of) => {
                self.visit_stmt(&for_of.body);
            }
            Stmt::While(while_stmt) => {
                self.visit_expr(&while_stmt.test);
                self.visit_stmt(&while_stmt.body);
            }
            Stmt::Try(try_stmt) => {
                for s in &try_stmt.block.stmts {
                    self.visit_stmt(s);
                }
                if let Some(handler) = &try_stmt.handler {
                    for s in &handler.body.stmts {
                        self.visit_stmt(s);
                    }
                }
                if let Some(finalizer) = &try_stmt.finalizer {
                    for s in &finalizer.stmts {
                        self.visit_stmt(s);
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
                    for s in &body.stmts {
                        self.visit_stmt(s);
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
                // Also visit arguments recursively
                for arg in &call.args {
                    self.visit_expr(&arg.expr);
                }
                // Visit callee for chained calls
                if let Callee::Expr(callee) = &call.callee {
                    self.visit_expr(callee);
                }
            }
            Expr::Arrow(arrow) => match &*arrow.body {
                BlockStmtOrExpr::BlockStmt(block) => {
                    for s in &block.stmts {
                        self.visit_stmt(s);
                    }
                }
                BlockStmtOrExpr::Expr(e) => self.visit_expr(e),
            },
            Expr::Fn(fn_expr) => {
                if let Some(body) = &fn_expr.function.body {
                    for s in &body.stmts {
                        self.visit_stmt(s);
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
            Expr::Assign(assign) => {
                self.visit_expr(&assign.right);
            }
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
                        PropOrSpread::Spread(spread) => {
                            self.visit_expr(&spread.expr);
                        }
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
            Expr::Member(member) => {
                self.visit_expr(&member.obj);
            }
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
        // Visit JSX attributes for expressions
        for attr in &jsx.opening.attrs {
            if let JSXAttrOrSpread::JSXAttr(attr) = attr {
                if let Some(JSXAttrValue::JSXExprContainer(container)) = &attr.value {
                    if let JSXExpr::Expr(expr) = &container.expr {
                        self.visit_expr(expr);
                    }
                }
            }
        }
        // Visit children
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
            JSXElementChild::JSXElement(element) => {
                self.visit_jsx_element(element);
            }
            JSXElementChild::JSXFragment(fragment) => {
                for c in &fragment.children {
                    self.visit_jsx_child(c);
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

        // Skip if this is a translation hook call itself
        if is_translation_hook(&func_name) {
            return;
        }

        // Check if this is a translation call
        if !is_member_t && !self.is_translation_call(&func_name, call) {
            return;
        }

        // Get the first argument
        let first_arg = match call.args.first() {
            Some(arg) => arg,
            None => return,
        };

        let value = match eval_string_expr(&first_arg.expr, self.consts) {
            Some(v) => v,
            None => return,
        };

        let (lnum, col, end_col) = span_to_loc(self.cm, first_arg.expr.span());

        // Check range
        if let Some(range) = self.range {
            if lnum < range.start_line || lnum > range.end_line {
                return;
            }
        }

        // Determine namespace
        let (key, ns, fallback) = self.resolve_namespace(&value, lnum);

        self.items.push(ScanItem {
            key,
            raw: value,
            namespace: ns,
            lnum,
            col,
            end_col,
            fallback,
        });
    }

    fn is_translation_call(&self, func_name: &str, call: &CallExpr) -> bool {
        if func_name == "t" {
            return true;
        }
        // Check if this function name matches any translation scope's t_func
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
        // Check for explicit namespace in key
        if let Some(colon_pos) = value.find(':') {
            let ns = &value[..colon_pos];
            return (value.to_string(), ns.to_string(), false);
        }

        // Find namespace from scopes
        for scope in self.scopes {
            if lnum >= scope.start_line && lnum <= scope.end_line {
                if let Some(ns) = &scope.ns {
                    let key = format!("{}:{}", ns, value);
                    return (key, ns.clone(), false);
                }
            }
        }

        // Use fallback namespace
        let ns = self.fallback_namespace.to_string();
        let key = format!("{}:{}", ns, value);
        (key, ns, true)
    }
}

/// A simpler approach: collect translation scopes by walking the AST and tracking
/// which function body we're in, and finding useTranslation calls within them.
fn collect_scopes_precise(
    module: &Module,
    cm: &SourceMap,
    consts: &HashMap<String, String>,
) -> Vec<NamespaceScope> {
    let mut collector = ScopeCollector {
        cm,
        consts,
        scopes: Vec::new(),
    };
    for item in &module.body {
        collector.visit_module_item(item, 0, u32::MAX);
    }
    // Sort by scope size (smallest first)
    collector.scopes.sort_by_key(|s| s.end_line - s.start_line);
    collector.scopes
}

struct ScopeCollector<'a> {
    cm: &'a SourceMap,
    consts: &'a HashMap<String, String>,
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
                            let (start, _, _) = span_to_loc(self.cm, body.span);
                            let hi = self.cm.lookup_char_pos(body.span.hi);
                            let end = hi.line as u32 - 1;
                            for s in &body.stmts {
                                self.visit_stmt(s, start, end);
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
                            let ns = get_first_string_arg(&call.args, self.consts);
                            self.scopes.push(NamespaceScope {
                                ns,
                                // Bare useTranslation("ns") implies default `t()` in this scope.
                                t_func: Some("t".to_string()),
                                start_line: scope_start,
                                end_line: scope_end,
                            });
                        }
                    }
                }
                self.visit_expr(&expr_stmt.expr, scope_start, scope_end)
            }
            Stmt::Return(ret) => {
                if let Some(arg) = &ret.arg {
                    self.visit_expr(arg, scope_start, scope_end);
                }
            }
            Stmt::Block(block) => {
                for s in &block.stmts {
                    self.visit_stmt(s, scope_start, scope_end);
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
                        // Check if this is a translation hook call
                        if let Some(call) = extract_hook_call(init.as_ref()) {
                            if let Some(name) = get_callee_name(&call.callee) {
                                if is_translation_hook(&name) {
                                    let ns = get_first_string_arg(&call.args, self.consts);
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
                        // Recurse into function expressions
                        self.visit_expr(init, scope_start, scope_end);
                    }
                }
            }
            Decl::Fn(fn_decl) => {
                if let Some(body) = &fn_decl.function.body {
                    let (start, _, _) = span_to_loc(self.cm, body.span);
                    let hi = self.cm.lookup_char_pos(body.span.hi);
                    let end = hi.line as u32 - 1;
                    for s in &body.stmts {
                        self.visit_stmt(s, start, end);
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
                    let (start, _, _) = span_to_loc(self.cm, block.span);
                    let hi = self.cm.lookup_char_pos(block.span.hi);
                    let end = hi.line as u32 - 1;
                    for s in &block.stmts {
                        self.visit_stmt(s, start, end);
                    }
                }
                BlockStmtOrExpr::Expr(e) => {
                    let (start, _, _) = span_to_loc(self.cm, arrow.span);
                    let hi = self.cm.lookup_char_pos(arrow.span.hi);
                    let end = hi.line as u32 - 1;
                    self.visit_expr(e, start, end);
                }
            },
            Expr::Fn(fn_expr) => {
                if let Some(body) = &fn_expr.function.body {
                    let (start, _, _) = span_to_loc(self.cm, body.span);
                    let hi = self.cm.lookup_char_pos(body.span.hi);
                    let end = hi.line as u32 - 1;
                    for s in &body.stmts {
                        self.visit_stmt(s, start, end);
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

pub fn extract(params: ExtractParams) -> Result<Value> {
    let (module, cm) = parse_module(&params.source, &params.lang)?;
    let consts = collect_consts(&module);
    let scopes = collect_scopes_precise(&module, &cm, &consts);
    let items = extract_calls(
        &module,
        &cm,
        &consts,
        &scopes,
        &params.fallback_namespace,
        &params.range,
    );
    Ok(serde_json::json!({ "items": items }))
}

pub fn extract_resource(params: ExtractResourceParams) -> Result<Value> {
    #[derive(Debug)]
    struct JsonLeaf {
        path: Vec<String>,
        lnum: u32,
        col: u32,
        end_col: u32,
    }

    struct JsonLeafScanner<'a> {
        source: &'a str,
        idx: usize,
        line: u32,
        col: u32,
        leaves: Vec<JsonLeaf>,
    }

    impl<'a> JsonLeafScanner<'a> {
        fn new(source: &'a str) -> Self {
            Self {
                source,
                idx: 0,
                line: 0,
                col: 0,
                leaves: Vec::new(),
            }
        }

        fn parse(mut self) -> Result<Vec<JsonLeaf>> {
            self.skip_ws();
            let mut path = Vec::new();
            self.parse_object(&mut path, false)?;
            self.skip_ws();
            if self.peek_char().is_some() {
                return Err(anyhow::anyhow!("unexpected trailing characters"));
            }
            Ok(self.leaves)
        }

        fn remaining(&self) -> &str {
            &self.source[self.idx..]
        }

        fn peek_char(&self) -> Option<char> {
            self.remaining().chars().next()
        }

        fn next_char(&mut self) -> Option<char> {
            let ch = self.peek_char()?;
            self.idx += ch.len_utf8();
            if ch == '\n' {
                self.line += 1;
                self.col = 0;
            } else {
                self.col += 1;
            }
            Some(ch)
        }

        fn consume_char(&mut self, target: char) -> bool {
            if self.peek_char() == Some(target) {
                let _ = self.next_char();
                true
            } else {
                false
            }
        }

        fn expect_char(&mut self, target: char) -> Result<()> {
            if self.consume_char(target) {
                Ok(())
            } else {
                Err(anyhow::anyhow!(
                    "expected '{}' at line {}, col {}",
                    target,
                    self.line,
                    self.col
                ))
            }
        }

        fn expect_literal(&mut self, literal: &str) -> Result<()> {
            for expected in literal.chars() {
                let actual = self.next_char();
                if actual != Some(expected) {
                    return Err(anyhow::anyhow!(
                        "expected '{}' at line {}, col {}",
                        literal,
                        self.line,
                        self.col
                    ));
                }
            }
            Ok(())
        }

        fn skip_ws(&mut self) {
            while matches!(self.peek_char(), Some(' ' | '\n' | '\r' | '\t')) {
                let _ = self.next_char();
            }
        }

        fn parse_string(&mut self) -> Result<(String, u32, u32, u32)> {
            let start_line = self.line;
            let start_col = self.col;
            self.expect_char('"')?;
            let mut out = String::new();
            loop {
                let ch = self
                    .next_char()
                    .ok_or_else(|| anyhow::anyhow!("unterminated string"))?;
                if ch == '"' {
                    return Ok((out, start_line, start_col, self.col));
                }
                if ch == '\\' {
                    let escaped = self
                        .next_char()
                        .ok_or_else(|| anyhow::anyhow!("unterminated escape sequence"))?;
                    match escaped {
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        '/' => out.push('/'),
                        'b' => out.push('\u{0008}'),
                        'f' => out.push('\u{000C}'),
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        'u' => {
                            let mut code: u32 = 0;
                            for _ in 0..4 {
                                let hex = self.next_char().ok_or_else(|| {
                                    anyhow::anyhow!("unterminated unicode escape")
                                })?;
                                let value = hex.to_digit(16).ok_or_else(|| {
                                    anyhow::anyhow!("invalid unicode escape at line {}", self.line)
                                })?;
                                code = (code << 4) | value;
                            }
                            if let Some(decoded) = char::from_u32(code) {
                                out.push(decoded);
                            }
                        }
                        _ => {
                            return Err(anyhow::anyhow!(
                                "invalid escape '{}' at line {}, col {}",
                                escaped,
                                self.line,
                                self.col
                            ));
                        }
                    }
                } else {
                    out.push(ch);
                }
            }
        }

        fn parse_number(&mut self) -> Result<()> {
            let _ = self.consume_char('-');

            match self.peek_char() {
                Some('0') => {
                    let _ = self.next_char();
                }
                Some('1'..='9') => {
                    let _ = self.next_char();
                    while matches!(self.peek_char(), Some('0'..='9')) {
                        let _ = self.next_char();
                    }
                }
                _ => {
                    return Err(anyhow::anyhow!(
                        "invalid number at line {}, col {}",
                        self.line,
                        self.col
                    ));
                }
            }

            if self.consume_char('.') {
                if !matches!(self.peek_char(), Some('0'..='9')) {
                    return Err(anyhow::anyhow!(
                        "invalid fraction at line {}, col {}",
                        self.line,
                        self.col
                    ));
                }
                while matches!(self.peek_char(), Some('0'..='9')) {
                    let _ = self.next_char();
                }
            }

            if matches!(self.peek_char(), Some('e' | 'E')) {
                let _ = self.next_char();
                if matches!(self.peek_char(), Some('+' | '-')) {
                    let _ = self.next_char();
                }
                if !matches!(self.peek_char(), Some('0'..='9')) {
                    return Err(anyhow::anyhow!(
                        "invalid exponent at line {}, col {}",
                        self.line,
                        self.col
                    ));
                }
                while matches!(self.peek_char(), Some('0'..='9')) {
                    let _ = self.next_char();
                }
            }

            Ok(())
        }

        fn push_leaf(&mut self, path: &[String], lnum: u32, col: u32, end_col: u32) {
            self.leaves.push(JsonLeaf {
                path: path.to_vec(),
                lnum,
                col,
                end_col,
            });
        }

        fn parse_object(&mut self, path: &mut Vec<String>, skip_emit: bool) -> Result<()> {
            self.expect_char('{')?;
            self.skip_ws();
            if self.consume_char('}') {
                return Ok(());
            }

            loop {
                let (key, key_line, key_col, key_end_col) = self.parse_string()?;
                self.skip_ws();
                self.expect_char(':')?;
                self.skip_ws();

                path.push(key);
                self.parse_object_value(path, skip_emit, key_line, key_col, key_end_col)?;
                let _ = path.pop();

                self.skip_ws();
                if self.consume_char(',') {
                    self.skip_ws();
                    continue;
                }
                self.expect_char('}')?;
                break;
            }

            Ok(())
        }

        fn parse_object_value(
            &mut self,
            path: &mut Vec<String>,
            skip_emit: bool,
            key_line: u32,
            key_col: u32,
            key_end_col: u32,
        ) -> Result<()> {
            match self.peek_char() {
                Some('{') => self.parse_object(path, skip_emit),
                Some('[') => self.parse_array(path),
                Some('"') => {
                    let _ = self.parse_string()?;
                    if !skip_emit {
                        self.push_leaf(path, key_line, key_col, key_end_col);
                    }
                    Ok(())
                }
                Some('-' | '0'..='9') => {
                    self.parse_number()?;
                    if !skip_emit {
                        self.push_leaf(path, key_line, key_col, key_end_col);
                    }
                    Ok(())
                }
                Some('t') => {
                    self.expect_literal("true")?;
                    if !skip_emit {
                        self.push_leaf(path, key_line, key_col, key_end_col);
                    }
                    Ok(())
                }
                Some('f') => {
                    self.expect_literal("false")?;
                    if !skip_emit {
                        self.push_leaf(path, key_line, key_col, key_end_col);
                    }
                    Ok(())
                }
                Some('n') => {
                    self.expect_literal("null")?;
                    if !skip_emit {
                        self.push_leaf(path, key_line, key_col, key_end_col);
                    }
                    Ok(())
                }
                _ => Err(anyhow::anyhow!(
                    "invalid value at line {}, col {}",
                    self.line,
                    self.col
                )),
            }
        }

        fn parse_array(&mut self, path: &mut Vec<String>) -> Result<()> {
            self.expect_char('[')?;
            self.skip_ws();
            if self.consume_char(']') {
                return Ok(());
            }
            loop {
                self.parse_array_value(path)?;
                self.skip_ws();
                if self.consume_char(',') {
                    self.skip_ws();
                    continue;
                }
                self.expect_char(']')?;
                break;
            }
            Ok(())
        }

        fn parse_array_value(&mut self, path: &mut Vec<String>) -> Result<()> {
            match self.peek_char() {
                Some('{') => self.parse_object(path, true),
                Some('[') => self.parse_array(path),
                Some('"') => {
                    let _ = self.parse_string()?;
                    Ok(())
                }
                Some('-' | '0'..='9') => self.parse_number(),
                Some('t') => self.expect_literal("true"),
                Some('f') => self.expect_literal("false"),
                Some('n') => self.expect_literal("null"),
                _ => Err(anyhow::anyhow!(
                    "invalid array value at line {}, col {}",
                    self.line,
                    self.col
                )),
            }
        }
    }

    let leaves = JsonLeafScanner::new(&params.source).parse()?;
    let mut items = Vec::new();

    for leaf in leaves {
        let in_range = match &params.range {
            Some(r) => leaf.lnum >= r.start_line && leaf.lnum <= r.end_line,
            None => true,
        };
        if !in_range {
            continue;
        }

        if params.is_root {
            if leaf.path.len() < 2 {
                continue;
            }
            let namespace = leaf.path[0].clone();
            let raw = leaf.path[1..].join(".");
            if raw.is_empty() {
                continue;
            }
            items.push(ScanItem {
                key: format!("{}:{}", namespace, raw),
                raw,
                namespace,
                lnum: leaf.lnum,
                col: leaf.col,
                end_col: leaf.end_col,
                fallback: false,
            });
        } else {
            if leaf.path.is_empty() {
                continue;
            }
            let raw = leaf.path.join(".");
            items.push(ScanItem {
                key: format!("{}:{}", params.namespace, raw),
                raw,
                namespace: params.namespace.clone(),
                lnum: leaf.lnum,
                col: leaf.col,
                end_col: leaf.end_col,
                fallback: false,
            });
        }
    }

    Ok(serde_json::json!({ "items": items }))
}

pub fn translation_context_at(params: TranslationContextParams) -> Result<Value> {
    let (module, cm) = parse_module(&params.source, &params.lang)?;
    let consts = collect_consts(&module);
    let scopes = collect_scopes_precise(&module, &cm, &consts);

    let row = params.row;
    let mut found_scope: Option<&NamespaceScope> = None;
    for scope in &scopes {
        if row >= scope.start_line && row <= scope.end_line {
            found_scope = Some(scope);
            break; // scopes are sorted by size, smallest first
        }
    }

    let result = TranslationContext {
        namespace: found_scope
            .and_then(|s| s.ns.clone())
            .unwrap_or(params.fallback_namespace),
        t_func: found_scope
            .and_then(|s| s.t_func.clone())
            .unwrap_or_else(|| "t".to_string()),
        found_hook: found_scope.is_some(),
        has_any_hook: !scopes.is_empty(),
    };

    Ok(serde_json::to_value(result)?)
}
