use std::collections::HashSet;

use swc_ecma_ast::*;

/// Upper bound on the distinct strings a single expression may expand to. Expressions that
/// exceed it are treated as unevaluable rather than enumerated.
pub(super) const MAX_STRING_CANDIDATES: usize = 64;
/// Upper bound on the total bytes of the candidate strings produced for one expression.
pub(super) const MAX_CANDIDATE_BYTES: usize = 64 * 1024;

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

/// Keep a candidate list only when it stays within the count and byte limits.
fn within_limits(candidates: Vec<String>) -> Option<Vec<String>> {
    let total_bytes: usize = candidates.iter().map(String::len).sum();
    (candidates.len() <= MAX_STRING_CANDIDATES && total_bytes <= MAX_CANDIDATE_BYTES)
        .then_some(candidates)
}

/// Combine every prefix with every suffix, dropping duplicates. Returns `None` when the
/// distinct result set would exceed the candidate limits.
fn concat_candidates(prefixes: &[String], suffixes: &[String]) -> Option<Vec<String>> {
    let mut seen = HashSet::new();
    let mut results = Vec::new();
    let mut total_bytes = 0usize;
    for prefix in prefixes {
        for suffix in suffixes {
            let value = format!("{prefix}{suffix}");
            if seen.contains(&value) {
                continue;
            }
            total_bytes = total_bytes.saturating_add(value.len());
            if results.len() == MAX_STRING_CANDIDATES || total_bytes > MAX_CANDIDATE_BYTES {
                return None;
            }
            seen.insert(value.clone());
            results.push(value);
        }
    }
    Some(results)
}

/// Expand an expression into its distinct candidate strings. An empty list means some required
/// part is dynamic; `None` means the expansion exceeded the candidate limits.
fn eval_string_candidates<F>(expr: &Expr, resolve_ident: &F) -> Option<Vec<String>>
where
    F: Fn(&Ident) -> Option<String>,
{
    match expr {
        Expr::Cond(cond) => {
            // Each branch contributes what it can; an unresolvable branch adds nothing.
            let mut results = eval_string_candidates(&cond.cons, resolve_ident)?;
            for value in eval_string_candidates(&cond.alt, resolve_ident)? {
                if !results.contains(&value) {
                    results.push(value);
                }
            }
            within_limits(results)
        }
        Expr::Bin(bin) if bin.op == BinaryOp::Add => {
            let lefts = eval_string_candidates(&bin.left, resolve_ident)?;
            let rights = eval_string_candidates(&bin.right, resolve_ident)?;
            concat_candidates(&lefts, &rights)
        }
        Expr::Tpl(tpl) => {
            let mut accum = vec![String::new()];
            for (i, quasi) in tpl.quasis.iter().enumerate() {
                let Some(quasi_str) = quasi.cooked.as_ref().and_then(wtf8_to_string) else {
                    return Some(Vec::new());
                };
                for value in &mut accum {
                    value.push_str(&quasi_str);
                }
                if let Some(expr) = tpl.exprs.get(i) {
                    let values = eval_string_candidates(expr, resolve_ident)?;
                    accum = concat_candidates(&accum, &values)?;
                    if accum.is_empty() {
                        return Some(accum);
                    }
                }
            }
            within_limits(accum)
        }
        Expr::Paren(paren) => eval_string_candidates(&paren.expr, resolve_ident),
        Expr::TsAs(ts_as) => eval_string_candidates(&ts_as.expr, resolve_ident),
        Expr::TsSatisfies(ts_sat) => eval_string_candidates(&ts_sat.expr, resolve_ident),
        Expr::TsNonNull(ts_nn) => eval_string_candidates(&ts_nn.expr, resolve_ident),
        Expr::TsConstAssertion(ts_const) => eval_string_candidates(&ts_const.expr, resolve_ident),
        _ => within_limits(eval_string_expr(expr, resolve_ident).into_iter().collect()),
    }
}

/// Evaluate an expression to every distinct static string it may produce, expanding
/// conditional branches. Returns an empty list when any part is dynamic or when the expansion
/// exceeds the candidate limits.
pub(super) fn eval_string_exprs<F>(expr: &Expr, resolve_ident: &F) -> Vec<String>
where
    F: Fn(&Ident) -> Option<String>,
{
    eval_string_candidates(expr, resolve_ident).unwrap_or_default()
}

#[cfg(test)]
mod tests;
