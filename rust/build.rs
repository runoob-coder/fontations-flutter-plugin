//! Exposes the resolved versions of the fontations crates to the Rust code,
//! so that `fontations_version()` can report them at runtime.

use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap_or_default());
    let lock = fs::read_to_string(manifest_dir.join("Cargo.lock")).unwrap_or_default();

    for name in ["skrifa", "read-fonts", "font-types"] {
        let version = find_version(&lock, name).unwrap_or_else(|| "unknown".to_string());
        let key = format!(
            "FONTATIONS_{}_VERSION",
            name.replace('-', "_").to_uppercase()
        );
        println!("cargo:rustc-env={key}={version}");
    }
}

fn find_version(lock: &str, wanted: &str) -> Option<String> {
    let mut current = None;
    for line in lock.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("name = ") {
            current = Some(rest.trim_matches('"').to_string());
        } else if let Some(rest) = line.strip_prefix("version = ") {
            if current.as_deref() == Some(wanted) {
                return Some(rest.trim_matches('"').to_string());
            }
        }
    }
    None
}
