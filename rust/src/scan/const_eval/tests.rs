use swc_ecma_ast::{Expr, ModuleItem, Stmt};

use super::*;
use crate::scan::parser::parse_module;

fn first_call_arg(source: &str) -> Box<Expr> {
    let (module, _cm) = parse_module(source, "tsx").expect("source should parse");
    let ModuleItem::Stmt(Stmt::Expr(expr_stmt)) = &module.body[0] else {
        panic!("expected expression statement");
    };
    let Expr::Call(call) = expr_stmt.expr.as_ref() else {
        panic!("expected call expression");
    };
    call.args[0].expr.clone()
}

fn no_idents(_: &Ident) -> Option<String> {
    None
}

#[test]
fn eval_string_exprs_expands_conditional_template_branches() {
    let expr = first_call_arg(r#"t(`${cond ? "a" : "b"}.title`);"#);
    let values = eval_string_exprs(&expr, &no_idents);

    assert_eq!(values, vec!["a.title".to_string(), "b.title".to_string()]);
}

#[test]
fn eval_string_expr_uses_cooked_template_text() {
    let expr = first_call_arg(r#"t(`rename.\u0074itle`);"#);

    assert_eq!(
        eval_string_expr(&expr, &no_idents),
        Some("rename.title".to_string())
    );
}

#[test]
fn eval_string_exprs_cooks_each_template_branch() {
    let expr = first_call_arg(r#"t(`rename.\u0074${cond ? "itle" : "ab"}`);"#);
    let values = eval_string_exprs(&expr, &no_idents);

    assert_eq!(
        values,
        vec!["rename.title".to_string(), "rename.tab".to_string()]
    );
}

#[test]
fn eval_string_exprs_resolves_identifiers_through_the_resolver() {
    let expr = first_call_arg(r#"t(prefix + ".title");"#);
    let values = eval_string_exprs(&expr, &|ident: &Ident| {
        (ident.sym.as_ref() == "prefix").then(|| "home".to_string())
    });

    assert_eq!(values, vec!["home.title".to_string()]);
}
