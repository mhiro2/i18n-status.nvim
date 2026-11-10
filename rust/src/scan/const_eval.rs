use swc_core::ecma::ast::*;

/// Upper bound on the distinct strings a single expression may expand to. Expressions that
/// exceed it are treated as unevaluable rather than enumerated.
pub(super) const MAX_STRING_CANDIDATES: usize = 64;
/// Upper bound on the total bytes of the candidate strings produced for one expression.
pub(super) const MAX_CANDIDATE_BYTES: usize = 64 * 1024;

/// Upper bound on the bytes that const substitution may produce while analyzing one source.
pub(super) const MAX_CONST_SUBSTITUTION_BYTES: usize = 1024 * 1024;

fn wtf8_to_string(atom: &swc_core::atoms::Wtf8Atom) -> Option<String> {
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

/// Whether `expr` only uses the forms `eval_string_expr` can evaluate. Other expressions are
/// dynamic regardless of the identifiers they reference.
pub(super) fn is_string_expr(expr: &Expr) -> bool {
    match expr {
        Expr::Lit(Lit::Str(_)) | Expr::Ident(_) => true,
        Expr::Tpl(tpl) => tpl.exprs.iter().all(|expr| is_string_expr(expr)),
        Expr::Bin(bin) if bin.op == BinaryOp::Add => {
            is_string_expr(&bin.left) && is_string_expr(&bin.right)
        }
        Expr::Paren(paren) => is_string_expr(&paren.expr),
        Expr::TsAs(ts_as) => is_string_expr(&ts_as.expr),
        Expr::TsSatisfies(ts_sat) => is_string_expr(&ts_sat.expr),
        Expr::TsNonNull(ts_nn) => is_string_expr(&ts_nn.expr),
        Expr::TsConstAssertion(ts_const) => is_string_expr(&ts_const.expr),
        _ => false,
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

/// One string a key expression may evaluate to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum KeyCandidate {
    /// The whole string is known statically.
    Exact(String),
    /// Only this leading part is known; the rest is decided at runtime.
    Prefix(String),
}

impl KeyCandidate {
    fn text(&self) -> &str {
        match self {
            Self::Exact(text) | Self::Prefix(text) => text,
        }
    }

    /// The candidate for `self` followed by `suffix`. A prefix absorbs whatever follows it.
    fn concat(&self, suffix: &Self) -> Self {
        match (self, suffix) {
            (Self::Exact(left), Self::Exact(right)) => Self::Exact(format!("{left}{right}")),
            (Self::Exact(left), Self::Prefix(right)) => Self::Prefix(format!("{left}{right}")),
            (Self::Prefix(_), _) => self.clone(),
        }
    }

    fn into_prefix(self) -> Self {
        match self {
            Self::Exact(text) => Self::Prefix(text),
            prefix @ Self::Prefix(_) => prefix,
        }
    }
}

/// Distinct candidates within the count and byte limits. Exact strings and prefixes have separate
/// allowances, so dynamic branches never cost an expression its statically known keys. Prefixes
/// beyond their allowance collapse into the empty prefix, which covers all of them.
#[derive(Default)]
struct CandidateSet {
    candidates: Vec<KeyCandidate>,
    exact_count: usize,
    exact_bytes: usize,
    prefix_count: usize,
    prefix_bytes: usize,
}

impl CandidateSet {
    /// Add `candidate` unless it is already present. Returns `None` when the exact strings would
    /// exceed the candidate limits.
    fn insert(&mut self, candidate: KeyCandidate) -> Option<()> {
        if self.candidates.contains(&candidate) {
            return Some(());
        }
        let len = candidate.text().len();
        match candidate {
            KeyCandidate::Exact(_) => {
                self.exact_bytes = self.exact_bytes.saturating_add(len);
                if self.exact_count == MAX_STRING_CANDIDATES
                    || self.exact_bytes > MAX_CANDIDATE_BYTES
                {
                    return None;
                }
                self.exact_count += 1;
            }
            KeyCandidate::Prefix(_) => {
                if self
                    .candidates
                    .contains(&KeyCandidate::Prefix(String::new()))
                {
                    // The empty prefix already covers every other prefix.
                    return Some(());
                }
                self.prefix_bytes = self.prefix_bytes.saturating_add(len);
                if self.prefix_count == MAX_STRING_CANDIDATES
                    || self.prefix_bytes > MAX_CANDIDATE_BYTES
                {
                    self.candidates
                        .retain(|candidate| matches!(candidate, KeyCandidate::Exact(_)));
                    self.candidates.push(KeyCandidate::Prefix(String::new()));
                    self.prefix_count = 1;
                    self.prefix_bytes = 0;
                    return Some(());
                }
                self.prefix_count += 1;
            }
        }
        self.candidates.push(candidate);
        Some(())
    }

    fn from_candidates(
        candidates: impl IntoIterator<Item = KeyCandidate>,
    ) -> Option<Vec<KeyCandidate>> {
        let mut set = Self::default();
        for candidate in candidates {
            set.insert(candidate)?;
        }
        Some(set.candidates)
    }
}

/// Combine every prefix with every suffix, dropping duplicates. Returns `None` when the
/// distinct result set would exceed the candidate limits.
fn concat_candidates(
    prefixes: &[KeyCandidate],
    suffixes: &[KeyCandidate],
) -> Option<Vec<KeyCandidate>> {
    CandidateSet::from_candidates(
        prefixes
            .iter()
            .flat_map(|prefix| suffixes.iter().map(|suffix| prefix.concat(suffix))),
    )
}

/// Expand a key expression into every distinct string it may produce, expanding conditional
/// branches. A part that cannot be evaluated statically turns the candidate into a `Prefix` of
/// the text known before it. Returns `None` when the expansion exceeds the candidate limits.
pub(super) fn eval_key_candidates<F>(expr: &Expr, resolve_ident: &F) -> Option<Vec<KeyCandidate>>
where
    F: Fn(&Ident) -> Option<String>,
{
    match expr {
        Expr::Cond(cond) => {
            let mut branches = eval_key_candidates(&cond.cons, resolve_ident)?;
            branches.extend(eval_key_candidates(&cond.alt, resolve_ident)?);
            CandidateSet::from_candidates(branches)
        }
        Expr::Bin(bin) if bin.op == BinaryOp::Add => {
            let lefts = eval_key_candidates(&bin.left, resolve_ident)?;
            let rights = eval_key_candidates(&bin.right, resolve_ident)?;
            concat_candidates(&lefts, &rights)
        }
        Expr::Tpl(tpl) => {
            let mut accum = vec![KeyCandidate::Exact(String::new())];
            for (i, quasi) in tpl.quasis.iter().enumerate() {
                let Some(quasi_str) = quasi.cooked.as_ref().and_then(wtf8_to_string) else {
                    return CandidateSet::from_candidates(
                        accum.into_iter().map(KeyCandidate::into_prefix),
                    );
                };
                accum = concat_candidates(&accum, &[KeyCandidate::Exact(quasi_str)])?;
                if let Some(expr) = tpl.exprs.get(i) {
                    let values = eval_key_candidates(expr, resolve_ident)?;
                    accum = concat_candidates(&accum, &values)?;
                }
            }
            Some(accum)
        }
        Expr::Paren(paren) => eval_key_candidates(&paren.expr, resolve_ident),
        Expr::TsAs(ts_as) => eval_key_candidates(&ts_as.expr, resolve_ident),
        Expr::TsSatisfies(ts_sat) => eval_key_candidates(&ts_sat.expr, resolve_ident),
        Expr::TsNonNull(ts_nn) => eval_key_candidates(&ts_nn.expr, resolve_ident),
        Expr::TsConstAssertion(ts_const) => eval_key_candidates(&ts_const.expr, resolve_ident),
        _ => CandidateSet::from_candidates([match eval_string_expr(expr, resolve_ident) {
            Some(value) => KeyCandidate::Exact(value),
            None => KeyCandidate::Prefix(String::new()),
        }]),
    }
}

#[cfg(test)]
mod tests;
