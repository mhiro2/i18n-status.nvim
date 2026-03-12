use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

mod call_extract;
mod const_eval;
mod parser;
mod resource_json;
mod scope;

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

pub fn extract(params: ExtractParams) -> Result<Value> {
    let (module, cm) = parser::parse_module(&params.source, &params.lang)?;
    let const_bindings = const_eval::collect_consts(&module, &cm);
    let scopes = scope::collect_scopes_precise(&module, &cm, &const_bindings);
    let items = call_extract::extract_calls(
        &module,
        &cm,
        &const_bindings,
        &scopes,
        &params.fallback_namespace,
        &params.range,
    );
    Ok(serde_json::json!({ "items": items }))
}

pub fn extract_resource(params: ExtractResourceParams) -> Result<Value> {
    resource_json::extract_resource(params)
}

pub fn translation_context_at(params: TranslationContextParams) -> Result<Value> {
    let (module, cm) = parser::parse_module(&params.source, &params.lang)?;
    let const_bindings = const_eval::collect_consts(&module, &cm);
    let scopes = scope::collect_scopes_precise(&module, &cm, &const_bindings);

    let found_scope = scopes
        .iter()
        .find(|scope| params.row >= scope.start_line && params.row <= scope.end_line);

    let result = TranslationContext {
        namespace: found_scope
            .and_then(|scope| scope.ns.clone())
            .unwrap_or(params.fallback_namespace),
        t_func: found_scope
            .and_then(|scope| scope.t_func.clone())
            .unwrap_or_else(|| "t".to_string()),
        found_hook: found_scope.is_some(),
        has_any_hook: !scopes.is_empty(),
    };

    Ok(serde_json::to_value(result)?)
}
