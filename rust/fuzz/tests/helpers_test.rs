// Unit tests for the byte-to-argument helpers: normal values, boundaries and
// malformed slices.

#[path = "../fuzz_targets/helpers.rs"]
mod helpers;

mod common;

// --- glyph_id ---------------------------------------------------------------

#[test]
fn glyph_id_reads_two_little_endian_bytes() {
    assert_eq!(helpers::glyph_id(&[]), 0);
    assert_eq!(helpers::glyph_id(&[0x41]), 0);
    assert_eq!(helpers::glyph_id(&[0x34, 0x12]), 0x1234);
    assert_eq!(helpers::glyph_id(&[0xff, 0xff, 0x41]), 0xffff);
}

// --- text -------------------------------------------------------------------

#[test]
fn text_truncates_bytes_and_chars() {
    assert_eq!(helpers::text(&[]), "");
    assert_eq!(helpers::text(b"AB"), "AB");
    assert_eq!(helpers::text(&vec![b'A'; 200]).len(), 64);
    // 96 bytes of 2-byte characters reach the byte cap first: 48 chars.
    assert_eq!(helpers::text("é".repeat(80).as_bytes()).chars().count(), 48);

    let lossy = helpers::text(&[0xff, 0xfe]);
    assert_eq!(lossy.chars().count(), 2);
    assert!(lossy.chars().all(|ch| ch == '\u{fffd}'));

    // The 96-byte cap can split a UTF-8 sequence.
    let mut split = vec![b'A'; 95];
    split.extend_from_slice(&[0xE2, 0x82, 0xAC]);
    assert_eq!(helpers::text(&split).chars().count(), 64);
}

// --- tag_at -----------------------------------------------------------------

#[test]
fn tag_at_handles_short_slices_and_huge_offsets() {
    assert_eq!(helpers::tag_at(b"headcmap", 0), "head");
    assert_eq!(helpers::tag_at(b"headcmap", 4), "cmap");
    assert_eq!(helpers::tag_at(b"head", 2), "ad");
    assert_eq!(helpers::tag_at(b"head", 4), "");
    assert_eq!(helpers::tag_at(b"", 0), "");
    assert_eq!(helpers::tag_at(b"head", usize::MAX), "");
    assert!(helpers::tag_at(&[0xff, 0xfe, 0x41, 0x42], 0).ends_with("AB"));
}

// --- variations -------------------------------------------------------------

#[test]
fn variations_are_bounded_and_deterministic() {
    let tags = ["wght", "wdth", "slnt", "opsz", "xxxx"];
    assert!(helpers::variations(&[]).is_empty());
    for seed in 0u16..256 {
        let data = common::pseudo_random(seed as u64, 5);
        let settings = helpers::variations(&data);
        assert!(settings.len() <= 2);
        assert!(settings.iter().all(|s| tags.contains(&s.tag.as_str())));
        assert!(settings.iter().all(|s| s.value.is_finite()));

        let again = helpers::variations(&data);
        assert_eq!(again.len(), settings.len());
        for (a, b) in settings.iter().zip(again.iter()) {
            assert_eq!(a.tag, b.tag);
            assert_eq!(a.value.to_bits(), b.value.to_bits());
        }
    }

    let one = helpers::variations(&[1, 0, 128]);
    assert_eq!(one.len(), 1);
    assert_eq!(one[0].tag, "wght");
    assert_eq!(one[0].value, 24.0);
}

// --- size -------------------------------------------------------------------

#[test]
fn size_covers_all_branches_and_missing_bytes() {
    assert_eq!(helpers::size(&[0, 10], 0), None);
    assert_eq!(helpers::size(&[1, 10], 0), Some(11.0));
    assert!(helpers::size(&[2, 10], 0).unwrap().is_nan());
    assert_eq!(helpers::size(&[3, 10], 0), Some(-1.0));
    assert_eq!(helpers::size(&[1], 0), Some(25.0));
    assert_eq!(helpers::size(&[255], 99), None);
}

// --- Arbitrary slices -------------------------------------------------------

#[test]
fn helpers_survive_arbitrary_slices() {
    for len in [0usize, 1, 2, 3, 4, 7, 96, 97, 512] {
        let data = common::pseudo_random(len as u64 + 1, len);
        let _ = helpers::glyph_id(&data);
        let _ = helpers::text(&data);
        let _ = helpers::tag_at(&data, 0);
        let _ = helpers::tag_at(&data, len / 2);
        let _ = helpers::tag_at(&data, usize::MAX);
        let _ = helpers::variations(&data);
        let _ = helpers::size(&data, 0);
        let _ = helpers::size(&data, len);
    }
}
