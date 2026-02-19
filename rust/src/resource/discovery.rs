use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
pub struct ResolveRootsParams {
    pub start_dir: String,
}

#[derive(Debug, Serialize)]
pub struct RootInfo {
    pub kind: String,
    pub path: String,
}

/// Walk up from `start_dir` looking for a subdirectory named `target`.
/// Returns the full path to the found directory, or None.
fn find_up(start_dir: &Path, target: &str) -> Option<PathBuf> {
    let mut current = start_dir.to_path_buf();
    loop {
        let candidate = current.join(target);
        if candidate.is_dir() {
            return Some(candidate);
        }
        if !current.pop() {
            return None;
        }
    }
}

pub fn resolve_roots(params: ResolveRootsParams) -> Result<Value> {
    let start = PathBuf::from(&params.start_dir);
    let mut roots: Vec<RootInfo> = Vec::new();

    // i18next: check public/locales/ first (more specific), then locales/
    if let Some(path) = find_up(&start, "public/locales") {
        roots.push(RootInfo {
            kind: "i18next".to_string(),
            path: path.to_string_lossy().to_string(),
        });
    } else if let Some(path) = find_up(&start, "locales") {
        roots.push(RootInfo {
            kind: "i18next".to_string(),
            path: path.to_string_lossy().to_string(),
        });
    }

    // next-intl: messages/
    if let Some(path) = find_up(&start, "messages") {
        roots.push(RootInfo {
            kind: "next-intl".to_string(),
            path: path.to_string_lossy().to_string(),
        });
    }

    Ok(serde_json::to_value(serde_json::json!({ "roots": roots }))?)
}
