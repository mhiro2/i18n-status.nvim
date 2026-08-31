#[cfg(test)]
use std::cell::Cell;
use std::collections::{HashMap, HashSet};

use swc_common::{SourceMap, Span, Spanned};
use swc_ecma_ast::*;
use swc_ecma_visit::{Visit, VisitWith};

use super::const_eval::{ConstBinding, eval_string_expr};
use super::parser::{span_to_lines, span_to_loc};

#[derive(Debug, Clone)]
pub(super) struct SymbolBinding {
    pub(super) namespace: Option<String>,
    pub(super) name: String,
    pub(super) translator: bool,
    hook: Option<String>,
    pub(super) start_line: u32,
    pub(super) end_line: u32,
    scope_start: u32,
    scope_end: u32,
    declaration_end: u32,
}

impl SymbolBinding {
    fn scope_width(&self) -> u32 {
        self.scope_end.saturating_sub(self.scope_start)
    }

    fn contains(&self, pos: u32) -> bool {
        pos >= self.scope_start && pos < self.scope_end
    }

    pub(super) fn is_callable_translator_at(&self, pos: u32) -> bool {
        self.translator && self.declaration_end <= pos
    }
}

#[derive(Debug, Default)]
pub(super) struct ScopeAnalysis {
    pub(super) bindings: Vec<SymbolBinding>,
    bindings_by_name: HashMap<String, NameBindingIndex>,
    translator_indices: Vec<usize>,
    #[cfg(test)]
    lookup_work: Cell<usize>,
}

#[derive(Debug)]
struct ScopeBindingGroup {
    scope_start: u32,
    scope_end: u32,
    binding_indices: Vec<usize>,
}

#[derive(Debug, Default)]
struct NameBindingIndex {
    binding_indices: Vec<usize>,
    scope_groups: Vec<ScopeBindingGroup>,
    ancestor_jumps: Vec<Vec<usize>>,
    laminar: bool,
}

impl NameBindingIndex {
    fn push(&mut self, index: usize) {
        self.binding_indices.push(index);
        self.scope_groups.clear();
        self.ancestor_jumps.clear();
        self.laminar = false;
    }

    fn rebuild(&mut self, bindings: &[SymbolBinding]) {
        let mut bindings_by_scope: HashMap<(u32, u32), Vec<usize>> = HashMap::new();
        for &index in &self.binding_indices {
            let binding = &bindings[index];
            bindings_by_scope
                .entry((binding.scope_start, binding.scope_end))
                .or_default()
                .push(index);
        }

        self.scope_groups = bindings_by_scope
            .into_iter()
            .map(|((scope_start, scope_end), mut binding_indices)| {
                binding_indices.sort_by_key(|&index| bindings[index].declaration_end);
                ScopeBindingGroup {
                    scope_start,
                    scope_end,
                    binding_indices,
                }
            })
            .collect();
        self.scope_groups.sort_by(|left, right| {
            left.scope_start
                .cmp(&right.scope_start)
                .then_with(|| right.scope_end.cmp(&left.scope_end))
        });

        self.laminar = true;
        let mut parents = vec![usize::MAX; self.scope_groups.len()];
        let mut stack: Vec<usize> = Vec::new();
        for (index, group) in self.scope_groups.iter().enumerate() {
            while stack.last().is_some_and(|&candidate| {
                self.scope_groups[candidate].scope_end <= group.scope_start
            }) {
                stack.pop();
            }
            if let Some(&parent) = stack.last() {
                if group.scope_end > self.scope_groups[parent].scope_end {
                    self.laminar = false;
                    break;
                }
                parents[index] = parent;
            }
            stack.push(index);
        }

        self.ancestor_jumps.clear();
        if !self.laminar || parents.is_empty() {
            return;
        }
        self.ancestor_jumps.push(parents);
        while (1usize << self.ancestor_jumps.len()) < self.scope_groups.len() {
            let previous = self
                .ancestor_jumps
                .last()
                .expect("ancestor jump table should be initialized");
            let next = previous
                .iter()
                .map(|&ancestor| {
                    if ancestor == usize::MAX {
                        usize::MAX
                    } else {
                        previous[ancestor]
                    }
                })
                .collect();
            self.ancestor_jumps.push(next);
        }
    }

    fn resolve_index(&self, bindings: &[SymbolBinding], pos: u32) -> (Option<usize>, usize) {
        if !self.laminar || self.scope_groups.is_empty() {
            return self.resolve_index_linear(bindings, pos);
        }

        let mut work = 0;
        let mut left = 0;
        let mut right = self.scope_groups.len();
        while left < right {
            work += 1;
            let middle = left + (right - left) / 2;
            if self.scope_groups[middle].scope_start <= pos {
                left = middle + 1;
            } else {
                right = middle;
            }
        }
        let Some(mut scope_index) = left.checked_sub(1) else {
            return (None, work);
        };

        work += 1;
        if self.scope_groups[scope_index].scope_end <= pos {
            for jumps in self.ancestor_jumps.iter().rev() {
                work += 1;
                let ancestor = jumps[scope_index];
                if ancestor != usize::MAX && self.scope_groups[ancestor].scope_end <= pos {
                    scope_index = ancestor;
                }
            }
            work += 1;
            let parent = self.ancestor_jumps[0][scope_index];
            if parent == usize::MAX || self.scope_groups[parent].scope_end <= pos {
                return (None, work);
            }
            scope_index = parent;
        }

        let group = &self.scope_groups[scope_index];
        let mut left = 0;
        let mut right = group.binding_indices.len();
        while left < right {
            work += 1;
            let middle = left + (right - left) / 2;
            if bindings[group.binding_indices[middle]].declaration_end <= pos {
                left = middle + 1;
            } else {
                right = middle;
            }
        }
        if left == 0 {
            return (group.binding_indices.first().copied(), work);
        }

        let declaration_end = bindings[group.binding_indices[left - 1]].declaration_end;
        let mut first = 0;
        let mut last = left;
        while first < last {
            work += 1;
            let middle = first + (last - first) / 2;
            if bindings[group.binding_indices[middle]].declaration_end < declaration_end {
                first = middle + 1;
            } else {
                last = middle;
            }
        }
        (Some(group.binding_indices[first]), work)
    }

    fn resolve_index_linear(&self, bindings: &[SymbolBinding], pos: u32) -> (Option<usize>, usize) {
        let mut minimum_width = None;
        let mut latest_declared: Option<usize> = None;
        let mut earliest_pending: Option<usize> = None;
        let mut examined = 0;
        for &index in &self.binding_indices {
            examined += 1;
            let binding = &bindings[index];
            if !binding.contains(pos) {
                continue;
            }

            let width = binding.scope_width();
            match minimum_width {
                Some(current) if width > current => continue,
                Some(current) if width < current => {
                    minimum_width = Some(width);
                    latest_declared = None;
                    earliest_pending = None;
                }
                None => minimum_width = Some(width),
                Some(_) => {}
            }

            if binding.declaration_end <= pos {
                if latest_declared.is_none_or(|current| {
                    binding.declaration_end > bindings[current].declaration_end
                }) {
                    latest_declared = Some(index);
                }
            } else if earliest_pending
                .is_none_or(|current| binding.declaration_end < bindings[current].declaration_end)
            {
                earliest_pending = Some(index);
            }
        }

        (latest_declared.or(earliest_pending), examined)
    }
}

impl ScopeAnalysis {
    fn push_binding(&mut self, binding: SymbolBinding) -> usize {
        let index = self.bindings.len();
        if binding.translator {
            self.translator_indices.push(index);
        }
        self.bindings_by_name
            .entry(binding.name.clone())
            .or_default()
            .push(index);
        self.bindings.push(binding);
        index
    }

    fn rebuild_indexes(&mut self) {
        self.bindings_by_name.clear();
        self.translator_indices.clear();
        for (index, binding) in self.bindings.iter().enumerate() {
            self.bindings_by_name
                .entry(binding.name.clone())
                .or_default()
                .binding_indices
                .push(index);
            if binding.translator {
                self.translator_indices.push(index);
            }
        }
        for index in self.bindings_by_name.values_mut() {
            index.rebuild(&self.bindings);
        }
    }

    pub(super) fn resolve(&self, name: &str, pos: u32) -> Option<&SymbolBinding> {
        let index = self.bindings_by_name.get(name)?;
        let (binding_index, work) = index.resolve_index(&self.bindings, pos);
        #[cfg(test)]
        self.lookup_work
            .set(self.lookup_work.get().saturating_add(work));
        #[cfg(not(test))]
        let _ = work;
        binding_index.map(|index| &self.bindings[index])
    }

    #[cfg(test)]
    pub(super) fn reset_lookup_work(&self) {
        self.lookup_work.set(0);
    }

    #[cfg(test)]
    pub(super) fn lookup_work(&self) -> usize {
        self.lookup_work.get()
    }

    pub(super) fn translators(&self) -> impl ExactSizeIterator<Item = &SymbolBinding> {
        self.translator_indices
            .iter()
            .map(|&index| &self.bindings[index])
    }

    fn canonical_hook_at(&self, name: &str, pos: u32) -> Option<String> {
        match self.resolve(name, pos) {
            Some(binding) => binding.hook.clone(),
            None if is_translation_hook(name) => Some(name.to_string()),
            None => None,
        }
    }

    pub(super) fn is_hook_call(&self, name: &str, pos: u32) -> bool {
        self.canonical_hook_at(name, pos).is_some()
    }

    pub(super) fn translator_context_at(
        &self,
        row: u32,
        pos: u32,
        callee: Option<&str>,
    ) -> (Option<&SymbolBinding>, bool, bool) {
        if let Some(callee) = callee {
            let resolved = self.resolve(callee, pos);
            let binding = resolved.filter(|binding| binding.is_callable_translator_at(pos));
            return (binding, false, resolved.is_some() && binding.is_none());
        }

        let mut resolved_names = HashSet::new();
        let mut candidates: Vec<_> = self
            .translators()
            .filter_map(|binding| {
                if !resolved_names.insert(binding.name.as_str()) {
                    return None;
                }
                let resolved = self.resolve(&binding.name, pos)?;
                (row >= resolved.start_line
                    && row <= resolved.end_line
                    && resolved.is_callable_translator_at(pos))
                .then_some(resolved)
            })
            .collect();
        let Some(minimum_width) = candidates.iter().map(|binding| binding.scope_width()).min()
        else {
            return (None, false, false);
        };
        candidates.retain(|binding| binding.scope_width() == minimum_width);

        match candidates.as_slice() {
            [binding] => (Some(*binding), false, false),
            [] => (None, false, false),
            _ => (None, true, false),
        }
    }
}

#[derive(Clone, Copy)]
struct ScopeRange {
    start_line: u32,
    end_line: u32,
    start_pos: u32,
    end_pos: u32,
}

struct PendingTranslator {
    binding_indices: Vec<usize>,
    pattern: Pat,
    hook_name: String,
    awaited: bool,
    namespace: Option<String>,
    call_pos: u32,
}

struct PendingCommonJsHook {
    binding_indices: Vec<usize>,
    hook: String,
    local_name: String,
    require_pos: u32,
}

struct PendingInvalidation {
    name: String,
    write_pos: u32,
    fallback_scope: ScopeRange,
}

pub(super) fn is_translation_hook(name: &str) -> bool {
    matches!(
        name,
        "useTranslation" | "useTranslations" | "getTranslations"
    )
}

fn imported_translation_hook(source: &str, imported: &str) -> Option<String> {
    let valid = matches!(
        (source, imported),
        ("react-i18next" | "next-i18next", "useTranslation")
            | ("next-intl", "useTranslations")
            | ("next-intl/server", "getTranslations")
    );
    valid.then(|| imported.to_string())
}

fn transparent_expr(expr: &Expr) -> &Expr {
    match expr {
        Expr::Paren(paren) => transparent_expr(&paren.expr),
        Expr::TsAs(ts_as) => transparent_expr(&ts_as.expr),
        Expr::TsSatisfies(ts_satisfies) => transparent_expr(&ts_satisfies.expr),
        Expr::TsNonNull(ts_non_null) => transparent_expr(&ts_non_null.expr),
        Expr::TsTypeAssertion(assertion) => transparent_expr(&assertion.expr),
        Expr::TsConstAssertion(assertion) => transparent_expr(&assertion.expr),
        Expr::TsInstantiation(instantiation) => transparent_expr(&instantiation.expr),
        _ => expr,
    }
}

fn require_source(expr: &Expr) -> Option<(&CallExpr, &str)> {
    let Expr::Call(call) = transparent_expr(expr) else {
        return None;
    };
    let Callee::Expr(callee) = &call.callee else {
        return None;
    };
    let Expr::Ident(identifier) = transparent_expr(callee) else {
        return None;
    };
    if identifier.sym.as_ref() != "require" || call.args.len() != 1 || call.args[0].spread.is_some()
    {
        return None;
    }
    let Expr::Lit(Lit::Str(source)) = transparent_expr(&call.args[0].expr) else {
        return None;
    };
    Some((call, source.value.as_str()?))
}

fn property_name(name: &PropName) -> Option<&str> {
    match name {
        PropName::Ident(identifier) => Some(identifier.sym.as_ref()),
        PropName::Str(value) => value.value.as_str(),
        PropName::Num(_) | PropName::BigInt(_) | PropName::Computed(_) => None,
    }
}

fn member_property_name(property: &MemberProp) -> Option<&str> {
    match property {
        MemberProp::Ident(identifier) => Some(identifier.sym.as_ref()),
        MemberProp::Computed(computed) => match transparent_expr(&computed.expr) {
            Expr::Lit(Lit::Str(value)) => value.value.as_str(),
            _ => None,
        },
        MemberProp::PrivateName(_) => None,
    }
}

fn local_pattern_name(pattern: &Pat) -> Option<&str> {
    match pattern {
        Pat::Ident(identifier) => Some(identifier.sym.as_ref()),
        Pat::Assign(assign) => local_pattern_name(&assign.left),
        _ => None,
    }
}

fn commonjs_hook_bindings(pattern: &Pat, init: &Expr) -> Vec<(String, String, u32)> {
    if let Pat::Object(object) = pattern {
        let Some((require, source)) = require_source(init) else {
            return Vec::new();
        };
        return object
            .props
            .iter()
            .filter_map(|property| {
                let (imported, local) = match property {
                    ObjectPatProp::Assign(assign) => {
                        (assign.key.sym.as_ref(), assign.key.sym.as_ref())
                    }
                    ObjectPatProp::KeyValue(key_value) => (
                        property_name(&key_value.key)?,
                        local_pattern_name(&key_value.value)?,
                    ),
                    ObjectPatProp::Rest(_) => return None,
                };
                let hook = imported_translation_hook(source, imported)?;
                Some((local.to_string(), hook, require.span.lo.0))
            })
            .collect();
    }

    let Pat::Ident(local) = pattern else {
        return Vec::new();
    };
    let Expr::Member(member) = transparent_expr(init) else {
        return Vec::new();
    };
    let Some((require, source)) = require_source(&member.obj) else {
        return Vec::new();
    };
    let Some(imported) = member_property_name(&member.prop) else {
        return Vec::new();
    };
    let Some(hook) = imported_translation_hook(source, imported) else {
        return Vec::new();
    };
    vec![(local.sym.to_string(), hook, require.span.lo.0)]
}

fn get_callee_name(callee: &Callee) -> Option<String> {
    match callee {
        Callee::Expr(expr) => match expr.as_ref() {
            Expr::Ident(ident) => Some(ident.sym.to_string()),
            _ => None,
        },
        _ => None,
    }
}

fn get_first_string_arg(
    args: &[ExprOrSpread],
    line: u32,
    const_bindings: &[ConstBinding],
) -> Option<String> {
    args.first()
        .and_then(|arg| eval_string_expr(&arg.expr, line, const_bindings))
}

fn extract_hook_call(expr: &Expr) -> Option<(&CallExpr, bool)> {
    match expr {
        Expr::Call(call) => Some((call, false)),
        Expr::Await(await_expr) => extract_hook_call(&await_expr.arg).map(|(call, _)| (call, true)),
        Expr::Paren(paren) => extract_hook_call(&paren.expr),
        Expr::TsAs(ts_as) => extract_hook_call(&ts_as.expr),
        Expr::TsSatisfies(ts_sat) => extract_hook_call(&ts_sat.expr),
        Expr::TsNonNull(ts_nn) => extract_hook_call(&ts_nn.expr),
        Expr::TsTypeAssertion(assertion) => extract_hook_call(&assertion.expr),
        Expr::TsConstAssertion(assertion) => extract_hook_call(&assertion.expr),
        Expr::TsInstantiation(instantiation) => extract_hook_call(&instantiation.expr),
        _ => None,
    }
}

fn destructured_t_name(name: &Pat) -> Option<String> {
    match name {
        Pat::Object(obj) => {
            for prop in &obj.props {
                match prop {
                    ObjectPatProp::Assign(assign) if assign.key.sym.as_ref() == "t" => {
                        return Some("t".to_string());
                    }
                    ObjectPatProp::KeyValue(kv) => {
                        if let PropName::Ident(key) = &kv.key {
                            if key.sym.as_ref() == "t" {
                                if let Pat::Ident(value) = &*kv.value {
                                    return Some(value.sym.to_string());
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
            None
        }
        Pat::Array(arr) => arr.elems.first().and_then(|elem| {
            elem.as_ref().and_then(|pat| match pat {
                Pat::Ident(ident) => Some(ident.sym.to_string()),
                _ => None,
            })
        }),
        _ => None,
    }
}

fn translation_binding_name(hook: &str, awaited: bool, pattern: &Pat) -> Option<String> {
    match hook {
        "useTranslation" if !awaited => destructured_t_name(pattern),
        "useTranslations" if !awaited => match pattern {
            Pat::Ident(ident) => Some(ident.sym.to_string()),
            _ => None,
        },
        "getTranslations" if awaited => match pattern {
            Pat::Ident(ident) => Some(ident.sym.to_string()),
            _ => None,
        },
        _ => None,
    }
}

fn pattern_names(pattern: &Pat, names: &mut Vec<String>) {
    match pattern {
        Pat::Ident(ident) => names.push(ident.sym.to_string()),
        Pat::Array(array) => {
            for element in array.elems.iter().flatten() {
                pattern_names(element, names);
            }
        }
        Pat::Object(object) => {
            for property in &object.props {
                match property {
                    ObjectPatProp::KeyValue(key_value) => pattern_names(&key_value.value, names),
                    ObjectPatProp::Assign(assign) => names.push(assign.key.sym.to_string()),
                    ObjectPatProp::Rest(rest) => pattern_names(&rest.arg, names),
                }
            }
        }
        Pat::Assign(assign) => pattern_names(&assign.left, names),
        Pat::Rest(rest) => pattern_names(&rest.arg, names),
        Pat::Expr(expression) => assignment_expression_names(expression, names),
        Pat::Invalid(_) => {}
    }
}

fn assignment_expression_names(expression: &Expr, names: &mut Vec<String>) {
    match expression {
        Expr::Ident(ident) => names.push(ident.sym.to_string()),
        Expr::Paren(paren) => assignment_expression_names(&paren.expr, names),
        Expr::TsAs(as_expr) => assignment_expression_names(&as_expr.expr, names),
        Expr::TsSatisfies(satisfies) => assignment_expression_names(&satisfies.expr, names),
        Expr::TsNonNull(non_null) => assignment_expression_names(&non_null.expr, names),
        Expr::TsTypeAssertion(assertion) => {
            assignment_expression_names(&assertion.expr, names);
        }
        Expr::TsInstantiation(instantiation) => {
            assignment_expression_names(&instantiation.expr, names);
        }
        _ => {}
    }
}

fn assignment_target_names(target: &AssignTarget, names: &mut Vec<String>) {
    match target {
        AssignTarget::Simple(simple) => match simple {
            SimpleAssignTarget::Ident(ident) => names.push(ident.id.sym.to_string()),
            SimpleAssignTarget::Paren(paren) => assignment_expression_names(&paren.expr, names),
            SimpleAssignTarget::TsAs(as_expr) => {
                assignment_expression_names(&as_expr.expr, names);
            }
            SimpleAssignTarget::TsSatisfies(satisfies) => {
                assignment_expression_names(&satisfies.expr, names);
            }
            SimpleAssignTarget::TsNonNull(non_null) => {
                assignment_expression_names(&non_null.expr, names);
            }
            SimpleAssignTarget::TsTypeAssertion(assertion) => {
                assignment_expression_names(&assertion.expr, names);
            }
            SimpleAssignTarget::TsInstantiation(instantiation) => {
                assignment_expression_names(&instantiation.expr, names);
            }
            SimpleAssignTarget::Member(_)
            | SimpleAssignTarget::SuperProp(_)
            | SimpleAssignTarget::OptChain(_)
            | SimpleAssignTarget::Invalid(_) => {}
        },
        AssignTarget::Pat(pattern) => {
            let pattern: Pat = pattern.clone().into();
            pattern_names(&pattern, names);
        }
    }
}

fn scope_range(cm: &SourceMap, span: Span) -> ScopeRange {
    let (start_line, end_line) = span_to_lines(cm, span);
    ScopeRange {
        start_line,
        end_line,
        start_pos: span.lo.0,
        end_pos: span.hi.0,
    }
}

pub(super) fn collect_scopes_precise(
    module: &Module,
    cm: &SourceMap,
    const_bindings: &[ConstBinding],
) -> ScopeAnalysis {
    let module_scope = ScopeRange {
        start_line: 0,
        end_line: u32::MAX,
        start_pos: 0,
        end_pos: u32::MAX,
    };
    let mut collector = ScopeCollector {
        cm,
        const_bindings,
        analysis: ScopeAnalysis::default(),
        pending_commonjs_hooks: Vec::new(),
        pending_invalidations: Vec::new(),
        pending_translators: Vec::new(),
        lexical_scopes: vec![module_scope],
        var_scopes: vec![module_scope],
    };
    module.visit_with(&mut collector);
    collector.analysis.rebuild_indexes();
    collector.finalize_invalidations();
    collector.analysis.rebuild_indexes();
    collector.finalize_commonjs_hooks();
    collector.finalize_translators();
    collector.analysis.bindings.sort_by_key(|binding| {
        (
            binding.scope_width(),
            binding.scope_start,
            binding.declaration_end,
        )
    });
    collector.analysis.rebuild_indexes();
    collector.analysis
}

struct ScopeCollector<'a> {
    cm: &'a SourceMap,
    const_bindings: &'a [ConstBinding],
    analysis: ScopeAnalysis,
    pending_commonjs_hooks: Vec<PendingCommonJsHook>,
    pending_invalidations: Vec<PendingInvalidation>,
    pending_translators: Vec<PendingTranslator>,
    lexical_scopes: Vec<ScopeRange>,
    var_scopes: Vec<ScopeRange>,
}

impl<'a> ScopeCollector<'a> {
    fn add_binding(
        &mut self,
        name: String,
        namespace: Option<String>,
        translator: bool,
        scope: ScopeRange,
        declaration_end: u32,
    ) -> usize {
        self.analysis.push_binding(SymbolBinding {
            namespace,
            name,
            translator,
            hook: None,
            start_line: scope.start_line,
            end_line: scope.end_line,
            scope_start: scope.start_pos,
            scope_end: scope.end_pos,
            declaration_end,
        })
    }

    fn add_hook_binding(
        &mut self,
        name: String,
        hook: String,
        scope: ScopeRange,
        declaration_end: u32,
    ) {
        let index = self.add_binding(name, None, false, scope, declaration_end);
        self.analysis.bindings[index].hook = Some(hook);
    }

    fn add_pattern_bindings(
        &mut self,
        pattern: &Pat,
        scope: ScopeRange,
        declaration_end: u32,
    ) -> Vec<usize> {
        let mut names = Vec::new();
        pattern_names(pattern, &mut names);
        let mut indices = Vec::with_capacity(names.len());
        for name in names {
            indices.push(self.add_binding(name, None, false, scope, declaration_end));
        }
        indices
    }

    fn record_commonjs_hooks(&mut self, pattern: &Pat, init: &Expr, binding_indices: &[usize]) {
        for (local_name, hook, require_pos) in commonjs_hook_bindings(pattern, init) {
            self.pending_commonjs_hooks.push(PendingCommonJsHook {
                binding_indices: binding_indices.to_vec(),
                hook,
                local_name,
                require_pos,
            });
        }
    }

    fn finalize_commonjs_hooks(&mut self) {
        for pending in std::mem::take(&mut self.pending_commonjs_hooks) {
            if self
                .analysis
                .resolve("require", pending.require_pos)
                .is_some()
            {
                continue;
            }
            for index in pending.binding_indices {
                let binding = &mut self.analysis.bindings[index];
                if binding.name == pending.local_name {
                    binding.hook = Some(pending.hook.clone());
                }
            }
        }
    }

    fn finalize_invalidations(&mut self) {
        let invalidations: Vec<_> = std::mem::take(&mut self.pending_invalidations)
            .into_iter()
            .map(|pending| {
                let scope = self
                    .analysis
                    .resolve(&pending.name, pending.write_pos)
                    .map(|binding| ScopeRange {
                        start_line: binding.start_line,
                        end_line: binding.end_line,
                        start_pos: binding.scope_start,
                        end_pos: binding.scope_end,
                    })
                    .unwrap_or(pending.fallback_scope);
                (pending.name, pending.write_pos, scope)
            })
            .collect();
        for (name, write_pos, scope) in invalidations {
            self.add_binding(name, None, false, scope, write_pos);
        }
    }

    fn finalize_translators(&mut self) {
        for pending in std::mem::take(&mut self.pending_translators) {
            let Some(hook) = self
                .analysis
                .canonical_hook_at(&pending.hook_name, pending.call_pos)
            else {
                continue;
            };
            let Some(translator_name) =
                translation_binding_name(&hook, pending.awaited, &pending.pattern)
            else {
                continue;
            };
            for index in pending.binding_indices {
                let binding = &mut self.analysis.bindings[index];
                if binding.name == translator_name {
                    binding.translator = true;
                    binding.namespace.clone_from(&pending.namespace);
                }
            }
        }
    }

    fn lexical_scope(&self) -> ScopeRange {
        *self.lexical_scopes.last().expect("lexical scope stack")
    }

    fn var_scope(&self) -> ScopeRange {
        *self.var_scopes.last().expect("var scope stack")
    }

    fn record_import(&mut self, import: &ImportDecl) {
        let scope = self.lexical_scope();
        let source = import.src.value.as_str().unwrap_or("");
        for specifier in &import.specifiers {
            let (local, imported) = match specifier {
                ImportSpecifier::Named(named) => {
                    let imported = named
                        .imported
                        .as_ref()
                        .map(|name| match name {
                            ModuleExportName::Ident(ident) => ident.sym.as_ref(),
                            ModuleExportName::Str(value) => value.value.as_str().unwrap_or(""),
                        })
                        .unwrap_or(named.local.sym.as_ref());
                    (named.local.sym.to_string(), Some(imported.to_string()))
                }
                ImportSpecifier::Default(default) => (default.local.sym.to_string(), None),
                ImportSpecifier::Namespace(namespace) => (namespace.local.sym.to_string(), None),
            };
            let hook = imported
                .as_deref()
                .and_then(|name| imported_translation_hook(source, name));
            if let Some(hook) = hook {
                self.add_hook_binding(local, hook, scope, scope.start_pos);
            } else {
                let imported_t = source == "i18next" && imported.as_deref() == Some("t");
                self.add_binding(local, None, imported_t, scope, scope.start_pos);
            }
        }
    }

    fn record_var_decl(&mut self, var: &VarDecl) {
        let binding_scope = if var.kind == VarDeclKind::Var {
            self.var_scope()
        } else {
            self.lexical_scope()
        };
        for declarator in &var.decls {
            let binding_indices =
                self.add_pattern_bindings(&declarator.name, binding_scope, declarator.span.hi.0);
            if let Some(init) = &declarator.init {
                self.record_commonjs_hooks(&declarator.name, init, &binding_indices);
                if let Some((call, awaited)) = extract_hook_call(init) {
                    if let Some(hook_name) = get_callee_name(&call.callee) {
                        let (call_line, _, _) = span_to_loc(self.cm, call.span);
                        self.pending_translators.push(PendingTranslator {
                            binding_indices,
                            pattern: declarator.name.clone(),
                            hook_name,
                            awaited,
                            namespace: get_first_string_arg(
                                &call.args,
                                call_line,
                                self.const_bindings,
                            ),
                            call_pos: call.span.lo.0,
                        });
                    }
                }
            }
        }
    }

    fn visit_function_body(&mut self, function: &Function, name: Option<&Ident>) {
        function.decorators.visit_with(self);
        for param in &function.params {
            param.decorators.visit_with(self);
        }
        let Some(body) = &function.body else {
            return;
        };
        let function_scope = scope_range(self.cm, function.span);
        let body_scope = scope_range(self.cm, body.span);
        self.lexical_scopes.push(function_scope);
        self.var_scopes.push(body_scope);
        if let Some(name) = name {
            self.add_binding(
                name.sym.to_string(),
                None,
                false,
                function_scope,
                function_scope.start_pos,
            );
        }
        for param in &function.params {
            self.add_pattern_bindings(&param.pat, function_scope, function_scope.start_pos);
        }
        for param in &function.params {
            param.pat.visit_with(self);
        }
        body.visit_with(self);
        self.var_scopes.pop();
        self.lexical_scopes.pop();
    }

    fn add_constructor_param(&mut self, param: &ParamOrTsParamProp, scope: ScopeRange) {
        match param {
            ParamOrTsParamProp::Param(param) => {
                self.add_pattern_bindings(&param.pat, scope, scope.start_pos);
            }
            ParamOrTsParamProp::TsParamProp(param) => match &param.param {
                TsParamPropParam::Ident(ident) => {
                    self.add_binding(
                        ident.id.sym.to_string(),
                        None,
                        false,
                        scope,
                        scope.start_pos,
                    );
                }
                TsParamPropParam::Assign(assign) => {
                    self.add_pattern_bindings(&assign.left, scope, scope.start_pos);
                }
            },
        }
    }

    fn invalidate_names(&mut self, mut names: Vec<String>, write_pos: u32) {
        names.sort_unstable();
        names.dedup();
        let fallback_scope = self.lexical_scope();
        for name in names {
            self.pending_invalidations.push(PendingInvalidation {
                name,
                write_pos,
                fallback_scope,
            });
        }
    }

    fn invalidate_for_head(&mut self, head: &ForHead, write_pos: u32) {
        let ForHead::Pat(pattern) = head else {
            return;
        };
        let mut names = Vec::new();
        pattern_names(pattern, &mut names);
        self.invalidate_names(names, write_pos);
    }

    fn visit_ts_namespace_body_scoped(&mut self, body: &TsNamespaceBody) {
        let namespace_scope = scope_range(self.cm, body.span());
        self.lexical_scopes.push(namespace_scope);
        self.var_scopes.push(namespace_scope);
        body.visit_children_with(self);
        self.var_scopes.pop();
        self.lexical_scopes.pop();
    }
}

impl Visit for ScopeCollector<'_> {
    fn visit_import_decl(&mut self, import: &ImportDecl) {
        self.record_import(import);
    }

    fn visit_var_decl(&mut self, var: &VarDecl) {
        self.record_var_decl(var);
        var.visit_children_with(self);
    }

    fn visit_using_decl(&mut self, declaration: &UsingDecl) {
        let scope = self.lexical_scope();
        for declarator in &declaration.decls {
            self.add_pattern_bindings(&declarator.name, scope, declarator.span.hi.0);
        }
        declaration.visit_children_with(self);
    }

    fn visit_ts_import_equals_decl(&mut self, declaration: &TsImportEqualsDecl) {
        let scope = self.lexical_scope();
        self.add_binding(
            declaration.id.sym.to_string(),
            None,
            false,
            scope,
            scope.start_pos,
        );
        declaration.module_ref.visit_with(self);
    }

    fn visit_ts_enum_decl(&mut self, declaration: &TsEnumDecl) {
        let scope = self.lexical_scope();
        self.add_binding(
            declaration.id.sym.to_string(),
            None,
            false,
            scope,
            declaration.span.hi.0,
        );
        declaration.members.visit_with(self);
    }

    fn visit_ts_module_decl(&mut self, declaration: &TsModuleDecl) {
        if !declaration.global {
            if let TsModuleName::Ident(identifier) = &declaration.id {
                let scope = self.lexical_scope();
                self.add_binding(
                    identifier.sym.to_string(),
                    None,
                    false,
                    scope,
                    declaration.span.hi.0,
                );
            }
        }
        if let Some(body) = &declaration.body {
            self.visit_ts_namespace_body_scoped(body);
        }
    }

    fn visit_ts_namespace_decl(&mut self, declaration: &TsNamespaceDecl) {
        if !declaration.global {
            let scope = self.lexical_scope();
            self.add_binding(
                declaration.id.sym.to_string(),
                None,
                false,
                scope,
                declaration.span.hi.0,
            );
        }
        self.visit_ts_namespace_body_scoped(&declaration.body);
    }

    fn visit_fn_decl(&mut self, declaration: &FnDecl) {
        let scope = self.lexical_scope();
        self.add_binding(
            declaration.ident.sym.to_string(),
            None,
            false,
            scope,
            scope.start_pos,
        );
        self.visit_function_body(&declaration.function, None);
    }

    fn visit_fn_expr(&mut self, expression: &FnExpr) {
        self.visit_function_body(&expression.function, expression.ident.as_ref());
    }

    fn visit_function(&mut self, function: &Function) {
        self.visit_function_body(function, None);
    }

    fn visit_arrow_expr(&mut self, arrow: &ArrowExpr) {
        let arrow_scope = scope_range(self.cm, arrow.span);
        let var_scope = match arrow.body.as_ref() {
            BlockStmtOrExpr::BlockStmt(block) => scope_range(self.cm, block.span),
            BlockStmtOrExpr::Expr(_) => arrow_scope,
        };
        self.lexical_scopes.push(arrow_scope);
        self.var_scopes.push(var_scope);
        for param in &arrow.params {
            self.add_pattern_bindings(param, arrow_scope, arrow_scope.start_pos);
        }
        for param in &arrow.params {
            param.visit_with(self);
        }
        arrow.body.visit_with(self);
        self.var_scopes.pop();
        self.lexical_scopes.pop();
    }

    fn visit_block_stmt(&mut self, block: &BlockStmt) {
        let block_scope = scope_range(self.cm, block.span);
        self.lexical_scopes.push(block_scope);
        block.stmts.visit_with(self);
        self.lexical_scopes.pop();
    }

    fn visit_catch_clause(&mut self, clause: &CatchClause) {
        let catch_scope = scope_range(self.cm, clause.body.span);
        self.lexical_scopes.push(catch_scope);
        if let Some(param) = &clause.param {
            self.add_pattern_bindings(param, catch_scope, catch_scope.start_pos);
            param.visit_with(self);
        }
        clause.body.stmts.visit_with(self);
        self.lexical_scopes.pop();
    }

    fn visit_for_stmt(&mut self, statement: &ForStmt) {
        let loop_scope = scope_range(self.cm, statement.span);
        self.lexical_scopes.push(loop_scope);
        statement.visit_children_with(self);
        self.lexical_scopes.pop();
    }

    fn visit_for_in_stmt(&mut self, statement: &ForInStmt) {
        let loop_scope = scope_range(self.cm, statement.span);
        self.lexical_scopes.push(loop_scope);
        self.invalidate_for_head(&statement.left, statement.body.span().lo.0);
        statement.visit_children_with(self);
        self.lexical_scopes.pop();
    }

    fn visit_for_of_stmt(&mut self, statement: &ForOfStmt) {
        let loop_scope = scope_range(self.cm, statement.span);
        self.lexical_scopes.push(loop_scope);
        self.invalidate_for_head(&statement.left, statement.body.span().lo.0);
        statement.visit_children_with(self);
        self.lexical_scopes.pop();
    }

    fn visit_switch_stmt(&mut self, statement: &SwitchStmt) {
        let switch_scope = scope_range(self.cm, statement.span);
        self.lexical_scopes.push(switch_scope);
        statement.visit_children_with(self);
        self.lexical_scopes.pop();
    }

    fn visit_class_decl(&mut self, declaration: &ClassDecl) {
        let scope = self.lexical_scope();
        self.add_binding(
            declaration.ident.sym.to_string(),
            None,
            false,
            scope,
            declaration.class.span.hi.0,
        );
        declaration.class.visit_with(self);
    }

    fn visit_class_expr(&mut self, expression: &ClassExpr) {
        let class_scope = scope_range(self.cm, expression.class.span);
        self.lexical_scopes.push(class_scope);
        if let Some(identifier) = &expression.ident {
            self.add_binding(
                identifier.sym.to_string(),
                None,
                false,
                class_scope,
                class_scope.start_pos,
            );
        }
        expression.class.visit_with(self);
        self.lexical_scopes.pop();
    }

    fn visit_constructor(&mut self, constructor: &Constructor) {
        constructor.key.visit_with(self);
        let Some(body) = &constructor.body else {
            constructor.params.visit_with(self);
            return;
        };
        let constructor_scope = scope_range(self.cm, constructor.span);
        let body_scope = scope_range(self.cm, body.span);
        self.lexical_scopes.push(constructor_scope);
        self.var_scopes.push(body_scope);
        for param in &constructor.params {
            self.add_constructor_param(param, constructor_scope);
        }
        constructor.params.visit_with(self);
        body.visit_with(self);
        self.var_scopes.pop();
        self.lexical_scopes.pop();
    }

    fn visit_getter_prop(&mut self, getter: &GetterProp) {
        getter.key.visit_with(self);
        getter.type_ann.visit_with(self);
        let Some(body) = &getter.body else {
            return;
        };
        let getter_scope = scope_range(self.cm, getter.span);
        let body_scope = scope_range(self.cm, body.span);
        self.lexical_scopes.push(getter_scope);
        self.var_scopes.push(body_scope);
        body.visit_with(self);
        self.var_scopes.pop();
        self.lexical_scopes.pop();
    }

    fn visit_setter_prop(&mut self, setter: &SetterProp) {
        setter.key.visit_with(self);
        let Some(body) = &setter.body else {
            setter.this_param.visit_with(self);
            setter.param.visit_with(self);
            return;
        };
        let setter_scope = scope_range(self.cm, setter.span);
        let body_scope = scope_range(self.cm, body.span);
        self.lexical_scopes.push(setter_scope);
        self.var_scopes.push(body_scope);
        if let Some(this_param) = &setter.this_param {
            self.add_pattern_bindings(this_param, setter_scope, setter_scope.start_pos);
        }
        self.add_pattern_bindings(&setter.param, setter_scope, setter_scope.start_pos);
        setter.this_param.visit_with(self);
        setter.param.visit_with(self);
        body.visit_with(self);
        self.var_scopes.pop();
        self.lexical_scopes.pop();
    }

    fn visit_static_block(&mut self, block: &StaticBlock) {
        let static_scope = scope_range(self.cm, block.span);
        self.lexical_scopes.push(static_scope);
        self.var_scopes.push(static_scope);
        block.body.visit_with(self);
        self.var_scopes.pop();
        self.lexical_scopes.pop();
    }

    fn visit_assign_expr(&mut self, assignment: &AssignExpr) {
        let mut names = Vec::new();
        assignment_target_names(&assignment.left, &mut names);
        self.invalidate_names(names, assignment.span.hi.0);
        assignment.visit_children_with(self);
    }

    fn visit_update_expr(&mut self, update: &UpdateExpr) {
        let mut names = Vec::new();
        assignment_expression_names(&update.arg, &mut names);
        self.invalidate_names(names, update.span.hi.0);
        update.visit_children_with(self);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::const_eval::collect_consts;
    use crate::scan::parser::parse_module;

    fn collect_scopes(source: &str) -> ScopeAnalysis {
        let (module, cm) = parse_module(source, "tsx").expect("source should parse");
        let const_bindings = collect_consts(&module, &cm);
        collect_scopes_precise(&module, &cm, &const_bindings)
    }

    #[test]
    fn collects_alias_from_destructured_hook_binding() {
        let scopes = collect_scopes(
            r#"
function Page() {
  const { t: tt } = useTranslation("dashboard");
  return tt("title");
}
"#,
        );
        let binding = scopes
            .bindings
            .iter()
            .find(|binding| binding.translator)
            .expect("translator binding should be collected");

        assert_eq!(binding.namespace.as_deref(), Some("dashboard"));
        assert_eq!(binding.name, "tt");
    }

    #[test]
    fn records_parameter_shadowing_inside_nested_function() {
        let scopes = collect_scopes(
            r#"
function Page() {
  const { t } = useTranslation("dashboard");
  return function Inner(t) { return t("title"); };
}
"#,
        );
        let nested = scopes
            .bindings
            .iter()
            .filter(|binding| binding.name == "t")
            .min_by_key(|binding| binding.scope_width())
            .expect("nested binding should exist");
        let binding = scopes
            .resolve("t", nested.scope_end - 1)
            .expect("shadow binding should resolve");

        assert!(!binding.translator);
    }

    #[test]
    fn rejects_unawaited_get_translations_binding() {
        let scopes = collect_scopes(
            r#"
async function Page() {
  const t = getTranslations("dashboard");
  return t("title");
}
"#,
        );

        assert_eq!(scopes.translators().count(), 0);
    }

    #[test]
    fn large_binding_sets_use_symbol_and_translator_indexes() {
        const BINDING_COUNT: usize = 10_000;
        let mut analysis = ScopeAnalysis::default();
        for index in 0..BINDING_COUNT {
            analysis.push_binding(SymbolBinding {
                namespace: None,
                name: format!("symbol_{index}"),
                translator: false,
                hook: None,
                start_line: 0,
                end_line: u32::MAX,
                scope_start: 0,
                scope_end: u32::MAX,
                declaration_end: 1,
            });
        }
        analysis.push_binding(SymbolBinding {
            namespace: Some("common".to_string()),
            name: "translate".to_string(),
            translator: true,
            hook: None,
            start_line: 0,
            end_line: u32::MAX,
            scope_start: 0,
            scope_end: u32::MAX,
            declaration_end: 1,
        });
        analysis.bindings.reverse();
        analysis.rebuild_indexes();

        analysis.reset_lookup_work();
        let resolved = analysis.resolve(&format!("symbol_{}", BINDING_COUNT - 1), 2);
        let lookup_work = analysis.lookup_work();
        let translators = analysis.translators();

        assert_eq!(analysis.bindings.len(), BINDING_COUNT + 1);
        assert_eq!(
            resolved.map(|binding| binding.name.as_str()),
            Some("symbol_9999")
        );
        assert!(lookup_work <= 4, "unexpected lookup work: {lookup_work}");
        assert_eq!(translators.len(), 1);

        analysis.reset_lookup_work();
        let (context, ambiguous, shadowed) = analysis.translator_context_at(0, 2, None);
        let context_lookup_work = analysis.lookup_work();
        assert_eq!(
            context.map(|binding| binding.name.as_str()),
            Some("translate")
        );
        assert!(
            context_lookup_work <= 4,
            "ordinary bindings affected context lookup: {context_lookup_work}"
        );
        assert!(!ambiguous);
        assert!(!shadowed);
    }

    #[test]
    fn same_position_bindings_keep_the_first_collected_symbol() {
        let mut analysis = ScopeAnalysis::default();
        for namespace in [Some("first".to_string()), Some("second".to_string())] {
            analysis.push_binding(SymbolBinding {
                namespace,
                name: "t".to_string(),
                translator: true,
                hook: None,
                start_line: 0,
                end_line: u32::MAX,
                scope_start: 0,
                scope_end: u32::MAX,
                declaration_end: 1,
            });
        }
        analysis.rebuild_indexes();

        let binding = analysis.resolve("t", 2).expect("binding should resolve");

        assert_eq!(binding.namespace.as_deref(), Some("first"));
    }
}
