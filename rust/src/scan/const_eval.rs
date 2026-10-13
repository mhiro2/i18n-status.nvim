use swc_ecma_ast::*;

/// Upper bound on the bytes that const substitution may produce while analyzing one source.
pub(super) const MAX_CONST_SUBSTITUTION_BYTES: usize = 1024 * 1024;

fn wtf8_to_string(atom: &swc_atoms::Wtf8Atom) -> Option<String> {
    atom.as_wtf8().as_str().map(ToOwned::to_owned)
}

/// Evaluate an expression to a single static string. `resolve_ident` returns the value of an
/// identifier as seen at its own position, or `None` when it is not a statically known string.
pub(super) fn eval_string_expr<F>(expr: &Expr, resolve_ident: &F) -> Option<String>
where
    F: Fn(&Ident) -> Option<String>,
{
    match expr {
        Expr::Lit(Lit::Str(s)) => wtf8_to_string(&s.value),
        Expr::Tpl(tpl) => {
            let mut result = String::new();
            for (i, quasi) in tpl.quasis.iter().enumerate() {
                result.push_str(&wtf8_to_string(quasi.cooked.as_ref()?)?);
                if let Some(expr) = tpl.exprs.get(i) {
                    let value = eval_string_expr(expr, resolve_ident)?;
                    result.push_str(&value);
                }
            }
            Some(result)
        }
        Expr::Bin(bin) if bin.op == BinaryOp::Add => {
            let left = eval_string_expr(&bin.left, resolve_ident)?;
            let right = eval_string_expr(&bin.right, resolve_ident)?;
            Some(format!("{}{}", left, right))
        }
        Expr::Ident(ident) => resolve_ident(ident),
        Expr::Paren(paren) => eval_string_expr(&paren.expr, resolve_ident),
        Expr::TsAs(ts_as) => eval_string_expr(&ts_as.expr, resolve_ident),
        Expr::TsSatisfies(ts_sat) => eval_string_expr(&ts_sat.expr, resolve_ident),
        Expr::TsNonNull(ts_nn) => eval_string_expr(&ts_nn.expr, resolve_ident),
        Expr::TsConstAssertion(ts_const) => eval_string_expr(&ts_const.expr, resolve_ident),
        _ => None,
    }
}

/// Collect the identifiers that `eval_string_expr` would resolve while evaluating `expr`.
pub(super) fn string_operand_idents<'a>(expr: &'a Expr, idents: &mut Vec<&'a Ident>) {
    match expr {
        Expr::Tpl(tpl) => {
            for expr in &tpl.exprs {
                string_operand_idents(expr, idents);
            }
        }
        Expr::Bin(bin) if bin.op == BinaryOp::Add => {
            string_operand_idents(&bin.left, idents);
            string_operand_idents(&bin.right, idents);
        }
        Expr::Ident(ident) => idents.push(ident),
        Expr::Paren(paren) => string_operand_idents(&paren.expr, idents),
        Expr::TsAs(ts_as) => string_operand_idents(&ts_as.expr, idents),
        Expr::TsSatisfies(ts_sat) => string_operand_idents(&ts_sat.expr, idents),
        Expr::TsNonNull(ts_nn) => string_operand_idents(&ts_nn.expr, idents),
        Expr::TsConstAssertion(ts_const) => string_operand_idents(&ts_const.expr, idents),
        _ => {}
    }
}

fn eval_string_exprs_multi<F>(expr: &Expr, resolve_ident: &F) -> Vec<String>
where
    F: Fn(&Ident) -> Option<String>,
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
                let Some(cooked) = &quasi.cooked else {
                    return Vec::new();
                };
                let Some(quasi_str) = wtf8_to_string(cooked) else {
                    return Vec::new();
                };
                if accum.is_empty() {
                    accum.push(quasi_str);
                } else {
                    for value in &mut accum {
                        value.push_str(&quasi_str);
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
        _ => eval_string_expr(expr, resolve_ident).into_iter().collect(),
    }
}

/// Evaluate an expression to every static string it may produce, expanding conditional
/// branches. Returns an empty list when any required part is dynamic.
pub(super) fn eval_string_exprs<F>(expr: &Expr, resolve_ident: &F) -> Vec<String>
where
    F: Fn(&Ident) -> Option<String>,
{
    eval_string_exprs_multi(expr, resolve_ident)
}

#[cfg(test)]
mod tests;
