use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use swc_common::{FileName, SourceMap, Spanned, input::SourceFileInput, sync::Lrc};
use swc_ecma_ast::*;
use swc_ecma_parser::{EsSyntax, Parser, Syntax, TsSyntax, lexer::Lexer};

/// Convert a Wtf8Atom (string literal value) to a Rust String
fn wtf8_to_string(atom: &swc_atoms::Wtf8Atom) -> String {
    atom.as_wtf8().as_str().unwrap_or_default().to_string()
}

use crate::scan::Range;

#[derive(Debug, Deserialize)]
pub struct ExtractParams {
    pub source: String,
    pub lang: String,
    pub range: Option<Range>,
    #[serde(default = "default_min_length")]
    pub min_length: usize,
    #[serde(default = "default_exclude_components")]
    pub exclude_components: Vec<String>,
}

fn default_min_length() -> usize {
    2
}

fn default_exclude_components() -> Vec<String> {
    vec!["Trans".to_string(), "Translation".to_string()]
}

#[derive(Debug, Serialize)]
pub struct HardcodedItem {
    pub lnum: u32,
    pub col: u32,
    pub end_lnum: u32,
    pub end_col: u32,
    pub text: String,
    pub kind: String, // "jsx_text" or "jsx_literal"
}

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

fn span_to_loc(cm: &SourceMap, span: swc_common::Span) -> (u32, u32, u32, u32) {
    let lo = cm.lookup_char_pos(span.lo);
    let hi = cm.lookup_char_pos(span.hi);
    (
        lo.line as u32 - 1,
        lo.col_display as u32,
        hi.line as u32 - 1,
        hi.col_display as u32,
    )
}

fn normalize_whitespace(text: &str) -> String {
    let result: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    result.trim().to_string()
}

/// Evaluate a literal expression (string, template without substitutions)
fn eval_literal(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Lit(Lit::Str(s)) => Some(wtf8_to_string(&s.value)),
        Expr::Tpl(tpl) => {
            if !tpl.exprs.is_empty() {
                return None;
            }
            let mut result = String::new();
            for quasi in &tpl.quasis {
                result.push_str(&quasi.raw);
            }
            Some(result)
        }
        Expr::Paren(paren) => eval_literal(&paren.expr),
        _ => None,
    }
}

/// Check if an expression is inside a t() call
fn is_inside_t_call(ancestors: &[AncestorInfo]) -> bool {
    for ancestor in ancestors.iter().rev() {
        if let AncestorKind::CallExpr(name) = &ancestor.kind {
            if name == "t" {
                return true;
            }
        }
    }
    false
}

/// Check if we're inside an excluded component
fn is_inside_excluded(ancestors: &[AncestorInfo], exclude_set: &HashSet<String>) -> bool {
    for ancestor in ancestors.iter().rev() {
        if let AncestorKind::JSXElement(name) = &ancestor.kind {
            if exclude_set.contains(name.as_str()) {
                // Also check short name
                let short = name.rsplit('.').next().unwrap_or(name);
                if exclude_set.contains(short) || exclude_set.contains(name.as_str()) {
                    return true;
                }
            }
            let short = name.rsplit('.').next().unwrap_or(name);
            if exclude_set.contains(short) {
                return true;
            }
        }
    }
    false
}

#[derive(Debug)]
enum AncestorKind {
    CallExpr(String),
    JSXElement(String),
}

#[derive(Debug)]
struct AncestorInfo {
    kind: AncestorKind,
}

fn in_range(start_line: u32, end_line: u32, range: &Option<Range>) -> bool {
    match range {
        None => true,
        Some(r) => end_line >= r.start_line && start_line <= r.end_line,
    }
}

struct HardcodedVisitor<'a> {
    cm: &'a SourceMap,
    range: &'a Option<Range>,
    min_length: usize,
    exclude_set: &'a HashSet<String>,
    items: Vec<HardcodedItem>,
    ancestors: Vec<AncestorInfo>,
}

impl<'a> HardcodedVisitor<'a> {
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
            Expr::JSXElement(jsx) => self.visit_jsx_element(jsx),
            Expr::JSXFragment(jsx) => {
                for child in &jsx.children {
                    self.visit_jsx_child(child);
                }
            }
            Expr::Call(call) => {
                // Track if this is a t() call
                let callee_name = match &call.callee {
                    Callee::Expr(e) => match e.as_ref() {
                        Expr::Ident(i) => Some(i.sym.to_string()),
                        Expr::Member(m) => {
                            if let MemberProp::Ident(p) = &m.prop {
                                Some(p.sym.to_string())
                            } else {
                                None
                            }
                        }
                        _ => None,
                    },
                    _ => None,
                };

                if let Some(name) = callee_name {
                    self.ancestors.push(AncestorInfo {
                        kind: AncestorKind::CallExpr(name),
                    });
                    for arg in &call.args {
                        self.visit_expr(&arg.expr);
                    }
                    self.ancestors.pop();
                } else {
                    for arg in &call.args {
                        self.visit_expr(&arg.expr);
                    }
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
            Expr::Cond(cond) => {
                self.visit_expr(&cond.test);
                self.visit_expr(&cond.cons);
                self.visit_expr(&cond.alt);
            }
            Expr::Array(arr) => {
                for elem in arr.elems.iter().flatten() {
                    self.visit_expr(&elem.expr);
                }
            }
            Expr::Object(obj) => {
                for prop in &obj.props {
                    if let PropOrSpread::Prop(prop) = prop {
                        if let Prop::KeyValue(kv) = prop.as_ref() {
                            self.visit_expr(&kv.value);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn visit_jsx_element(&mut self, jsx: &JSXElement) {
        let component_name = get_jsx_element_name(&jsx.opening);

        self.ancestors.push(AncestorInfo {
            kind: AncestorKind::JSXElement(component_name),
        });

        // Visit attributes
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

        self.ancestors.pop();
    }

    fn visit_jsx_child(&mut self, child: &JSXElementChild) {
        match child {
            JSXElementChild::JSXText(text) => {
                self.check_jsx_text(text);
            }
            JSXElementChild::JSXExprContainer(container) => {
                if let JSXExpr::Expr(expr) = &container.expr {
                    self.check_jsx_literal(expr, container.span);
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

    fn check_jsx_text(&mut self, text: &JSXText) {
        let (start_line, start_col, end_line, end_col) = span_to_loc(self.cm, text.span);

        if !in_range(start_line, end_line, self.range) {
            return;
        }

        if is_inside_excluded(&self.ancestors, self.exclude_set) {
            return;
        }

        if is_inside_t_call(&self.ancestors) {
            return;
        }

        let normalized = normalize_whitespace(&text.value);
        if normalized.len() >= self.min_length {
            self.items.push(HardcodedItem {
                lnum: start_line,
                col: start_col,
                end_lnum: end_line,
                end_col,
                text: normalized,
                kind: "jsx_text".to_string(),
            });
        }
    }

    fn check_jsx_literal(&mut self, expr: &Expr, span: swc_common::Span) {
        let (start_line, _, end_line, _) = span_to_loc(self.cm, span);

        if !in_range(start_line, end_line, self.range) {
            return;
        }

        if is_inside_excluded(&self.ancestors, self.exclude_set) {
            return;
        }

        if is_inside_t_call(&self.ancestors) {
            return;
        }

        if let Some(literal) = eval_literal(expr) {
            let trimmed = literal.trim().to_string();
            if trimmed.len() >= self.min_length {
                let (lnum, col, end_lnum, end_col) = span_to_loc(self.cm, expr.span());
                self.items.push(HardcodedItem {
                    lnum,
                    col,
                    end_lnum,
                    end_col,
                    text: literal,
                    kind: "jsx_literal".to_string(),
                });
            }
        }
    }
}

fn get_jsx_element_name(opening: &JSXOpeningElement) -> String {
    match &opening.name {
        JSXElementName::Ident(ident) => ident.sym.to_string(),
        JSXElementName::JSXMemberExpr(member) => {
            format!("{}.{}", jsx_object_name(&member.obj), member.prop.sym)
        }
        JSXElementName::JSXNamespacedName(ns) => {
            format!("{}:{}", ns.ns.sym, ns.name.sym)
        }
    }
}

fn jsx_object_name(obj: &JSXObject) -> String {
    match obj {
        JSXObject::Ident(ident) => ident.sym.to_string(),
        JSXObject::JSXMemberExpr(member) => {
            format!("{}.{}", jsx_object_name(&member.obj), member.prop.sym)
        }
    }
}

pub fn extract(params: ExtractParams) -> Result<Value> {
    let (module, cm) = parse_module(&params.source, &params.lang)?;

    let exclude_set: HashSet<String> = params.exclude_components.into_iter().collect();

    let mut visitor = HardcodedVisitor {
        cm: &cm,
        range: &params.range,
        min_length: params.min_length,
        exclude_set: &exclude_set,
        items: Vec::new(),
        ancestors: Vec::new(),
    };

    visitor.visit_module(&module);

    // Sort by position
    visitor
        .items
        .sort_by(|a, b| a.lnum.cmp(&b.lnum).then(a.col.cmp(&b.col)));

    Ok(serde_json::json!({ "items": visitor.items }))
}
