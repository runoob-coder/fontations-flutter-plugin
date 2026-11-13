// Deterministic replays of every fuzz target: normal flow, malformed input,
// seed corpus and configuration contracts. No libFuzzer runtime is needed.

#[path = "../fuzz_targets/cases.rs"]
mod cases;

mod common;

use std::fs;
use std::path::Path;

use fontations::api::fontations::Font;

const FONT_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../example/assets/fonts/Inter.ttf"
);
const SEEDS_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/seeds");

fn replay(data: &[u8]) {
    for target in [
        cases::run_font_entry,
        cases::run_shape,
        cases::run_outline,
        cases::run_varc_color,
        cases::run_modify,
    ] {
        target(data);
    }
}

// --- Normal flow ------------------------------------------------------------

#[test]
fn a_real_font_reaches_every_target() {
    let bytes = fs::read(FONT_PATH).expect("example Inter.ttf");
    let font = Font::from_bytes(bytes.clone(), None).expect("valid font");
    assert!(font.char_to_glyph(0x41).unwrap().is_some());
    let shaped = font
        .shape("AV".to_string(), Some(24.0), vec![], None, None, None)
        .expect("shape succeeds");
    assert!(!shaped.glyphs.is_empty());
    replay(&bytes);
}

// --- Malformed and boundary inputs ------------------------------------------

#[test]
fn empty_garbage_and_boundary_inputs_never_panic() {
    let mut inputs = vec![
        vec![],
        vec![0],
        b"OTTO".to_vec(),
        vec![0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        vec![0xff; 8192],
        vec![b'A'; 8192],
    ];
    for len in [2usize, 3, 4, 5, 12, 96, 97, 512, 4096] {
        inputs.push(common::pseudo_random(len as u64, len));
    }
    for input in &inputs {
        replay(input);
    }
}

#[test]
fn long_input_stays_bounded() {
    replay(&common::pseudo_random(7, 100_000));
}

// --- Seed corpus ------------------------------------------------------------

#[test]
fn seeds_and_mutations_replay_without_panics() {
    let seeds: Vec<_> = fs::read_dir(SEEDS_DIR)
        .expect("seeds/")
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.is_file())
        .collect();
    assert!(seeds.len() >= 3, "committed seed corpus is missing");

    for path in seeds {
        let bytes = fs::read(&path).unwrap();
        assert!(!bytes.is_empty(), "{} is empty", path.display());
        replay(&bytes);
        for mutated in common::mutations(&bytes) {
            replay(&mutated);
        }
    }
}

#[test]
fn seed_magic_numbers_and_dictionary_are_intact() {
    let sfnt = fs::read(Path::new(SEEDS_DIR).join("sfnt_empty.bin")).unwrap();
    assert_eq!(&sfnt[..4], &[0, 1, 0, 0]);
    let otto = fs::read(Path::new(SEEDS_DIR).join("otto_empty.bin")).unwrap();
    assert_eq!(&otto[..4], b"OTTO");

    let dict = fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/font.dict")).unwrap();
    for token in [
        "magic_sfnt",
        "magic_otto",
        "magic_ttcf",
        "tag_glyf",
        "tag_cmap",
        "tag_colr",
        "tag_varc",
    ] {
        assert!(dict.contains(token), "missing dictionary token {token}");
    }
}

// --- Configuration ----------------------------------------------------------

#[test]
fn all_targets_are_declared_in_the_manifest() {
    let manifest = fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml")).unwrap();
    for name in [
        "fuzz_font_entry",
        "fuzz_shape",
        "fuzz_outline",
        "fuzz_varc_color",
        "fuzz_modify",
    ] {
        assert!(
            manifest.contains(&format!("name = \"{name}\"")),
            "missing bin {name}"
        );
    }
}
