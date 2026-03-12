use swc_common::Spanned;
use swc_ecma_ast::{Expr, ModuleItem, Stmt};

use super::*;
use crate::scan::parser::{parse_module, span_to_loc};

fn first_call_arg(source: &str) -> (Box<Expr>, u32) {
    let (module, cm) = parse_module(source, "tsx").expect("source should parse");
    let ModuleItem::Stmt(Stmt::Expr(expr_stmt)) = &module.body[0] else {
        panic!("expected expression statement");
    };
    let Expr::Call(call) = expr_stmt.expr.as_ref() else {
        panic!("expected call expression");
    };
    let arg = call.args[0].expr.clone();
    let (line, _, _) = span_to_loc(&cm, arg.span());
    (arg, line)
}

#[test]
fn resolve_const_prefers_narrower_scope_then_latest_decl() {
    let bindings = vec![
        ConstBinding {
            name: "KEY".to_string(),
            value: "outer".to_string(),
            scope_start: 0,
            scope_end: 20,
            decl_line: 1,
            order: 0,
        },
        ConstBinding {
            name: "KEY".to_string(),
            value: "inner".to_string(),
            scope_start: 5,
            scope_end: 10,
            decl_line: 6,
            order: 1,
        },
    ];

    assert_eq!(
        resolve_const_at_line("KEY", 8, &bindings),
        Some("inner".to_string())
    );
    assert_eq!(
        resolve_const_at_line("KEY", 12, &bindings),
        Some("outer".to_string())
    );
}

#[test]
fn eval_string_exprs_expands_conditional_template_branches() {
    let (expr, line) = first_call_arg(r#"t(`${cond ? "a" : "b"}.title`);"#);
    let values = eval_string_exprs(&expr, line, &[]);

    assert_eq!(values, vec!["a.title".to_string(), "b.title".to_string()]);
}
