use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

mod call_extract;
mod const_eval;
pub(crate) mod parser;
mod resource_json;
mod scope;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanItem {
    pub key: String,
    pub raw: String,
    pub namespace: String,
    pub lnum: u32,
    pub col: u32,
    pub end_lnum: u32,
    pub end_col: u32,
    pub fallback: bool,
    pub refactorable: bool,
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
    #[serde(default)]
    pub col: Option<u32>,
    #[serde(default)]
    pub callee: Option<String>,
    #[serde(default)]
    pub member_call: bool,
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
    pub ambiguous: bool,
    pub shadowed: bool,
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
    let pos = source_byte_pos(&params.source, params.row, params.col);
    let (module, cm) = parser::parse_module(&params.source, &params.lang)?;
    let const_bindings = const_eval::collect_consts(&module, &cm);
    let scopes = scope::collect_scopes_precise(&module, &cm, &const_bindings);

    let (found_scope, ambiguous, shadowed) = if params.member_call {
        (None, false, false)
    } else {
        scopes.translator_context_at(params.row, pos, params.callee.as_deref())
    };

    let result = TranslationContext {
        namespace: found_scope
            .and_then(|scope| scope.namespace.clone())
            .unwrap_or(params.fallback_namespace),
        t_func: found_scope
            .map(|scope| scope.name.clone())
            .unwrap_or_else(|| "t".to_string()),
        found_hook: found_scope.is_some(),
        has_any_hook: scopes.translators().next().is_some(),
        ambiguous,
        shadowed,
    };

    Ok(serde_json::to_value(result)?)
}

fn source_byte_pos(source: &str, row: u32, col: Option<u32>) -> u32 {
    let mut offset = 0usize;
    let mut selected = "";
    for (index, line) in source.split('\n').enumerate() {
        if index == row as usize {
            selected = line;
            break;
        }
        offset = offset.saturating_add(line.len()).saturating_add(1);
    }
    let column = col.map_or(selected.len(), |value| value as usize);
    let column = column.min(selected.len());
    u32::try_from(offset.saturating_add(column).saturating_add(1)).unwrap_or(u32::MAX)
}
