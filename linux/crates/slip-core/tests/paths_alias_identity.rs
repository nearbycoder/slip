use std::path::{Path, PathBuf};

use slip_core::alias::{generate_alias, ADJECTIVES, FRUITS};
use slip_core::identity::{sha256_hex, Identity};
use slip_core::model::Protocol;
use slip_core::paths::{destination, sanitize_relative_path, unique_path};

#[test]
fn sanitize_strips_traversal_and_absolute() {
    assert_eq!(sanitize_relative_path("a.png"), PathBuf::from("a.png"));
    assert_eq!(sanitize_relative_path("/etc/passwd"), PathBuf::from("etc/passwd"));
    assert_eq!(sanitize_relative_path("../../x"), PathBuf::from("x"));
    assert_eq!(sanitize_relative_path("a/./b/../c.txt"), PathBuf::from("a/b/c.txt"));
    assert_eq!(sanitize_relative_path("..\\..\\win\\evil.exe"), PathBuf::from("win/evil.exe"));
    assert_eq!(sanitize_relative_path("Photos/2024/a.jpg"), PathBuf::from("Photos/2024/a.jpg"));
    assert_eq!(sanitize_relative_path("//a//b"), PathBuf::from("a/b"));
    assert_eq!(sanitize_relative_path(""), PathBuf::from("file"));
    assert_eq!(sanitize_relative_path("../.."), PathBuf::from("file"));
    assert_eq!(sanitize_relative_path("..."), PathBuf::from("file"));
}

#[test]
fn sanitize_replaces_illegal_chars() {
    assert_eq!(sanitize_relative_path("a<b>c:d\"e|f?g*h.txt"), PathBuf::from("a_b_c_d_e_f_g_h.txt"));
    assert_eq!(sanitize_relative_path("new\nline\0.txt"), PathBuf::from("new_line_.txt"));
    assert_eq!(sanitize_relative_path("trailing. "), PathBuf::from("trailing"));
    let long = "x".repeat(400);
    let p = sanitize_relative_path(&long);
    assert!(p.to_string_lossy().len() <= 240);
}

#[test]
fn sanitized_paths_never_escape() {
    let base = Path::new("/save");
    for evil in ["../a", "/../../a", "a/../../../b", "..\\..\\c", "./../d", "C:\\Windows\\x", "~/../e"] {
        let p = base.join(sanitize_relative_path(evil));
        assert!(p.starts_with(base), "{evil} → {}", p.display());
        assert!(!p.components().any(|c| matches!(c, std::path::Component::ParentDir)), "{evil}");
    }
}

#[test]
fn unique_names_append_counter_before_extension() {
    let dir = tempfile::tempdir().unwrap();
    let a = dir.path().join("a.tar.gz");
    assert_eq!(unique_path(&a), a);
    std::fs::write(&a, b"1").unwrap();
    assert_eq!(unique_path(&a), dir.path().join("a.tar (1).gz"));
    std::fs::write(dir.path().join("a.tar (1).gz"), b"2").unwrap();
    assert_eq!(unique_path(&a), dir.path().join("a.tar (2).gz"));
    std::fs::write(dir.path().join("README"), b"x").unwrap();
    assert_eq!(destination(dir.path(), "README"), dir.path().join("README (1)"));
    std::fs::write(dir.path().join(".hidden"), b"x").unwrap();
    assert_eq!(destination(dir.path(), ".hidden"), dir.path().join(".hidden (1)"));
}

#[test]
fn alias_shape() {
    for _ in 0..200 {
        let a = generate_alias();
        let (adj, fruit) = a.split_once(' ').expect("two words");
        assert!(ADJECTIVES.contains(&adj), "{adj}");
        assert!(FRUITS.contains(&fruit), "{fruit}");
    }
}

#[test]
fn alias_lists_match_protocol_json() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../protocol/aliases.json");
    let Ok(bytes) = std::fs::read(&path) else {
        eprintln!("skipping: {} not found", path.display());
        return;
    };
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let adjs: Vec<&str> = v["adjectives"].as_array().unwrap().iter().map(|s| s.as_str().unwrap()).collect();
    let fruits: Vec<&str> = v["fruits"].as_array().unwrap().iter().map(|s| s.as_str().unwrap()).collect();
    assert_eq!(adjs, ADJECTIVES);
    assert_eq!(fruits, FRUITS);
}

#[test]
fn fingerprint_is_sha256_of_cert_der() {
    let id = Identity::generate().unwrap();
    assert_eq!(id.cert_fingerprint, sha256_hex(&id.cert_der));
    assert_eq!(id.cert_fingerprint.len(), 64);
    assert!(id.cert_fingerprint.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    assert_eq!(id.http_fingerprint.len(), 32);
    assert!(id.http_fingerprint.chars().all(|c| c.is_ascii_hexdigit()));
    assert_eq!(id.fingerprint(Protocol::Https), id.cert_fingerprint);
    assert_eq!(id.fingerprint(Protocol::Http), id.http_fingerprint);
    assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

#[test]
fn identity_persists_across_loads() {
    let dir = tempfile::tempdir().unwrap();
    let a = Identity::load_or_create(dir.path()).unwrap();
    let b = Identity::load_or_create(dir.path()).unwrap();
    assert_eq!(a.cert_fingerprint, b.cert_fingerprint);
    assert_eq!(a.http_fingerprint, b.http_fingerprint);
    assert!(dir.path().join("cert.pem").exists());
    assert!(dir.path().join("key.pem").exists());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(dir.path().join("key.pem")).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0, "private key must not be group/world readable");
    }
    // Corrupt cert → regenerated.
    std::fs::write(dir.path().join("cert.pem"), b"garbage").unwrap();
    let c = Identity::load_or_create(dir.path()).unwrap();
    assert_ne!(c.cert_fingerprint, a.cert_fingerprint);
    assert_eq!(c.http_fingerprint, a.http_fingerprint);
}

#[test]
fn settings_round_trip_and_defaults() {
    use slip_core::settings::Settings;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("settings.json");
    let s = Settings::load_or_default(&path);
    assert!(path.exists());
    assert_eq!(s.port, 53317);
    assert!(s.https);
    assert!(s.discoverable);
    let again = Settings::load_or_default(&path);
    assert_eq!(s, again);
    // Partial / unknown keys are tolerated.
    std::fs::write(&path, br#"{"alias":"Kind Mango","port":53350,"unknown":true}"#).unwrap();
    let p = Settings::load_or_default(&path);
    assert_eq!(p.alias, "Kind Mango");
    assert_eq!(p.port, 53350);
    assert!(p.https);
}
