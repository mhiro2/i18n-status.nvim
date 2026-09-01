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

fn push_root(roots: &mut Vec<RootInfo>, kind: &str, path: PathBuf) {
    let path = path.canonicalize().unwrap_or(path);
    let path = path.to_string_lossy().into_owned();
    if roots
        .iter()
        .any(|root| root.kind == kind && root.path == path)
    {
        return;
    }
    roots.push(RootInfo {
        kind: kind.to_string(),
        path,
    });
}

pub fn resolve_roots(params: ResolveRootsParams) -> Result<Value> {
    let start = PathBuf::from(&params.start_dir);
    let mut roots: Vec<RootInfo> = Vec::new();

    // Report every supported i18next root so callers can reject ambiguity.
    if let Some(path) = find_up(&start, "public/locales") {
        push_root(&mut roots, "i18next", path);
    }
    if let Some(path) = find_up(&start, "locales") {
        push_root(&mut roots, "i18next", path);
    }

    // next-intl: messages/
    if let Some(path) = find_up(&start, "messages") {
        push_root(&mut roots, "next-intl", path);
    }

    Ok(serde_json::to_value(serde_json::json!({ "roots": roots }))?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_project(label: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should follow the Unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "i18n-status-discovery-{label}-{}-{unique}",
            std::process::id()
        ))
    }

    #[test]
    fn reports_all_detected_i18next_roots() {
        let project = temporary_project("all-roots");
        let source = project.join("src");
        let public_locales = project.join("public/locales");
        let locales = project.join("locales");
        fs::create_dir_all(&source).expect("source directory should be created");
        fs::create_dir_all(&public_locales).expect("public locales should be created");
        fs::create_dir_all(&locales).expect("locales should be created");

        let result = resolve_roots(ResolveRootsParams {
            start_dir: source.to_string_lossy().into_owned(),
        })
        .expect("root discovery should succeed");
        let public_locales = public_locales
            .canonicalize()
            .expect("public locales should be canonicalized");
        let locales = locales
            .canonicalize()
            .expect("locales should be canonicalized");
        fs::remove_dir_all(&project).expect("temporary project should be removed");

        let roots = result["roots"]
            .as_array()
            .expect("roots should be returned as an array");
        assert_eq!(roots.len(), 2);
        assert_eq!(roots[0]["kind"], "i18next");
        assert_eq!(roots[0]["path"], public_locales.to_string_lossy().as_ref());
        assert_eq!(roots[1]["kind"], "i18next");
        assert_eq!(roots[1]["path"], locales.to_string_lossy().as_ref());
    }

    #[test]
    fn deduplicates_public_locales_for_sources_below_public() {
        let project = temporary_project("public-source");
        let source = project.join("public/src");
        let public_locales = project.join("public/locales");
        fs::create_dir_all(&source).expect("source directory should be created");
        fs::create_dir_all(&public_locales).expect("public locales should be created");

        let result = resolve_roots(ResolveRootsParams {
            start_dir: source.to_string_lossy().into_owned(),
        })
        .expect("root discovery should succeed");
        let public_locales = public_locales
            .canonicalize()
            .expect("public locales should be canonicalized");
        fs::remove_dir_all(&project).expect("temporary project should be removed");

        let roots = result["roots"]
            .as_array()
            .expect("roots should be returned as an array");
        assert_eq!(roots.len(), 1);
        assert_eq!(roots[0]["kind"], "i18next");
        assert_eq!(roots[0]["path"], public_locales.to_string_lossy().as_ref());
    }
}
