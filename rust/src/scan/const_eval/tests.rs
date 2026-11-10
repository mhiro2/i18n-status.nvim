use std::fmt::Write as _;

use swc_core::ecma::ast::{Expr, ModuleItem, Stmt};

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

/// Statically known strings of `expr`, or `None` when the expansion exceeds the limits.
fn eval_string_exprs<F>(expr: &Expr, resolve_ident: &F) -> Option<Vec<String>>
where
    F: Fn(&Ident) -> Option<String>,
{
    let candidates = eval_key_candidates(expr, resolve_ident)?;
    Some(
        candidates
            .into_iter()
            .filter_map(|candidate| match candidate {
                KeyCandidate::Exact(value) => Some(value),
                KeyCandidate::Prefix(_) => None,
            })
            .collect(),
    )
}

#[test]
fn eval_string_exprs_expands_conditional_template_branches() {
    let expr = first_call_arg(r#"t(`${cond ? "a" : "b"}.title`);"#);
    let values = eval_string_exprs(&expr, &no_idents).unwrap();

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
    let values = eval_string_exprs(&expr, &no_idents).unwrap();

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
    })
    .unwrap();

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

    assert_eq!(
        eval_string_exprs(&expr, &no_idents),
        Some(vec!["a".repeat(14)])
    );
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
    assert!(eval_key_candidates(&expr, &no_idents).is_none());
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
        eval_string_exprs(&expr, &no_idents).map(|values| values.len()),
        Some(MAX_STRING_CANDIDATES)
    );
}

#[test]
fn eval_string_exprs_rejects_literals_over_the_byte_limit() {
    let source = format!("t(\"{}\");", "a".repeat(MAX_CANDIDATE_BYTES + 1));
    let expr = first_call_arg(&source);

    assert!(eval_key_candidates(&expr, &no_idents).is_none());
}

#[test]
fn eval_string_exprs_rejects_conditional_branches_over_the_byte_limit() {
    let half = "a".repeat(MAX_CANDIDATE_BYTES / 2 + 1);
    let source = format!("t(flag ? \"{half}x\" : \"{half}y\");");
    let expr = first_call_arg(&source);

    assert!(eval_key_candidates(&expr, &no_idents).is_none());
}

#[test]
fn eval_key_candidates_keeps_the_static_prefix_of_dynamic_parts() {
    use KeyCandidate::{Exact, Prefix};

    for (source, expected) in [
        ("t(`errors.${code}`);", vec![Prefix("errors.".to_string())]),
        (
            r#"t("errors." + code + ".title");"#,
            vec![Prefix("errors.".to_string())],
        ),
        ("t(code);", vec![Prefix(String::new())]),
        ("t(getKey());", vec![Prefix(String::new())]),
        (
            r#"t(flag ? "home.title" : `home.${section}`);"#,
            vec![Exact("home.title".to_string()), Prefix("home.".to_string())],
        ),
        (
            "t(`${flag ? \"a\" : section}.title`);",
            vec![Exact("a.title".to_string()), Prefix(String::new())],
        ),
    ] {
        let expr = first_call_arg(source);
        assert_eq!(
            eval_key_candidates(&expr, &no_idents),
            Some(expected),
            "{source}"
        );
    }
}

#[test]
fn eval_key_candidates_deduplicates_prefixes_that_absorb_their_suffixes() {
    let expr = first_call_arg("t(`a.${x}` + (flag ? \".b\" : \".c\"));");

    assert_eq!(
        eval_key_candidates(&expr, &no_idents),
        Some(vec![KeyCandidate::Prefix("a.".to_string())])
    );
}

#[test]
fn eval_key_candidates_keeps_static_keys_at_the_limit_beside_dynamic_branches() {
    let mut source = "t(flag ? \"\"".to_string();
    for index in 0..6 {
        write!(source, " + (flag{index} ? \"a\" : \"b\")").expect("write to string");
    }
    source.push_str(" : runtimeKey);");
    let expr = first_call_arg(&source);

    let candidates = eval_key_candidates(&expr, &no_idents).expect("within the limits");
    let exact = candidates
        .iter()
        .filter(|candidate| matches!(candidate, KeyCandidate::Exact(_)))
        .count();
    assert_eq!(exact, MAX_STRING_CANDIDATES);
    assert!(candidates.contains(&KeyCandidate::Prefix(String::new())));
}

#[test]
fn eval_key_candidates_collapses_prefixes_over_the_limit() {
    // 64 static heads, each followed by one of two dynamic tails, give 128 distinct prefixes.
    let mut source = "t(\"\"".to_string();
    for index in 0..6 {
        write!(source, " + (flag{index} ? \"a\" : \"b\")").expect("write to string");
    }
    source.push_str(" + (other ? `c${x}` : `d${x}`));");
    let expr = first_call_arg(&source);

    assert_eq!(
        eval_key_candidates(&expr, &no_idents),
        Some(vec![KeyCandidate::Prefix(String::new())])
    );
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
