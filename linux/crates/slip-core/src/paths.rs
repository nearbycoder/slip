//! Safe mapping of sender-supplied file names to paths under the save directory.

use std::path::{Component, Path, PathBuf};

/// Characters we never allow in a path segment (illegal on common filesystems, or
/// troublesome for other clients reading the same disk).
const ILLEGAL: &[char] = &['<', '>', ':', '"', '|', '?', '*', '\0'];

fn sanitize_segment(seg: &str) -> Option<String> {
    let cleaned: String = seg
        .chars()
        .map(|c| if ILLEGAL.contains(&c) || c.is_control() { '_' } else { c })
        .collect();
    // Trailing dots/spaces are invalid on Windows/exFAT; trim them.
    let cleaned = cleaned.trim().trim_end_matches(['.', ' ']).to_string();
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        None
    } else {
        // Keep each segment within the usual 255-byte limit.
        Some(truncate_utf8(&cleaned, 240))
    }
}

fn truncate_utf8(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

/// Turn a sender-supplied `fileName` (which may contain `/` for folder sends) into a
/// relative path that can never escape the save directory.
///
/// Strips leading `/`, drops `.`/`..`/empty segments, treats `\` as a separator and
/// replaces illegal characters with `_`. Returns `"file"` if nothing usable remains.
pub fn sanitize_relative_path(file_name: &str) -> PathBuf {
    let normalised = file_name.replace('\\', "/");
    let mut out = PathBuf::new();
    for seg in normalised.split('/') {
        if let Some(s) = sanitize_segment(seg) {
            out.push(s);
        }
    }
    if out.as_os_str().is_empty() {
        out.push("file");
    }
    debug_assert!(out.components().all(|c| matches!(c, Component::Normal(_))));
    out
}

/// If `path` exists, append ` (1)`, ` (2)`, … before the extension until it doesn't.
pub fn unique_path(path: &Path) -> PathBuf {
    if !path.exists() {
        return path.to_path_buf();
    }
    let parent = path.parent().map(Path::to_path_buf).unwrap_or_default();
    let file_name = path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let (stem, ext) = split_ext(&file_name);
    for n in 1.. {
        let candidate = parent.join(format!("{stem} ({n}){ext}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    unreachable!()
}

/// `"a.tar.gz"` → (`"a.tar"`, `".gz"`); `".bashrc"` → (`".bashrc"`, `""`).
fn split_ext(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(0) | None => (name, ""),
        Some(i) => (&name[..i], &name[i..]),
    }
}

/// Resolve the final destination for `file_name` under `save_dir`.
pub fn destination(save_dir: &Path, file_name: &str) -> PathBuf {
    unique_path(&save_dir.join(sanitize_relative_path(file_name)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split() {
        assert_eq!(split_ext("a.png"), ("a", ".png"));
        assert_eq!(split_ext(".bashrc"), (".bashrc", ""));
        assert_eq!(split_ext("noext"), ("noext", ""));
    }
}
