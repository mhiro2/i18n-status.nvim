use anyhow::{Context, Result};
use serde_json::Value;
use std::path::Path;

/// Read and parse a JSON file.
pub fn read_json_file(path: &Path) -> Result<Value> {
    let content =
        std::fs::read_to_string(path).with_context(|| format!("failed to read {:?}", path))?;
    let value: Value =
        serde_json::from_str(&content).with_context(|| format!("failed to parse {:?}", path))?;
    Ok(value)
}

/// Get the modification time of a file as nanoseconds since UNIX epoch.
pub fn file_mtime(path: &Path) -> Result<u64> {
    let metadata = std::fs::metadata(path).with_context(|| format!("failed to stat {:?}", path))?;
    let modified = metadata
        .modified()
        .with_context(|| format!("failed to get mtime for {:?}", path))?;
    let duration = modified
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    Ok(duration
        .as_secs()
        .saturating_mul(1_000_000_000)
        .saturating_add(duration.subsec_nanos() as u64))
}
