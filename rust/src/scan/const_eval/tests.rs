use std::fmt::Write as _;

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

#[test]
fn eval_string_exprs_deduplicates_equivalent_branches() {
    let mut source = "t(\"\"".to_string();
    for _ in 0..14 {
        source.push_str(" + (flag ? \"a\" : \"a\")");
    }
    source.push_str(");");
    let expr = first_call_arg(&source);

    assert_eq!(eval_string_exprs(&expr, &no_idents), vec!["a".repeat(14)]);
}

#[test]
fn eval_string_exprs_rejects_expansions_over_the_candidate_limit() {
    let mut source = "t(\"\"".to_string();
    for index in 0..7 {
        write!(source, " + (flag{index} ? \"a\" : \"b\")").expect("write to string");
    }
    source.push_str(");");
    let expr = first_call_arg(&source);

    assert!(2usize.pow(7) > MAX_STRING_CANDIDATES);
    assert!(eval_string_exprs(&expr, &no_idents).is_empty());
}

#[test]
fn eval_string_exprs_keeps_expansions_at_the_candidate_limit() {
    let mut source = "t(\"\"".to_string();
    for index in 0..6 {
        write!(source, " + (flag{index} ? \"a\" : \"b\")").expect("write to string");
    }
    source.push_str(");");
    let expr = first_call_arg(&source);

    assert_eq!(
        eval_string_exprs(&expr, &no_idents).len(),
        MAX_STRING_CANDIDATES
    );
}

#[test]
fn eval_string_exprs_rejects_literals_over_the_byte_limit() {
    let source = format!("t(\"{}\");", "a".repeat(MAX_CANDIDATE_BYTES + 1));
    let expr = first_call_arg(&source);

    assert!(eval_string_exprs(&expr, &no_idents).is_empty());
}

#[test]
fn eval_string_exprs_rejects_conditional_branches_over_the_byte_limit() {
    let half = "a".repeat(MAX_CANDIDATE_BYTES / 2 + 1);
    let source = format!("t(flag ? \"{half}x\" : \"{half}y\");");
    let expr = first_call_arg(&source);

    assert!(eval_string_exprs(&expr, &no_idents).is_empty());
}

#[test]
fn is_string_expr_accepts_only_evaluable_forms() {
    for source in [
        r#"f("a")"#,
        "f(key)",
        r#"f(`${prefix}.${"title"}`)"#,
        r#"f(("a" + key) as const)"#,
    ] {
        assert!(is_string_expr(&first_call_arg(source)), "{source}");
    }
    for source in [
        "f(() => key)",
        r#"f(flag ? "a" : "b")"#,
        "f(readKey())",
        r#"f(`${readKey()}`)"#,
        r#"f("a" - key)"#,
    ] {
        assert!(!is_string_expr(&first_call_arg(source)), "{source}");
    }
}
