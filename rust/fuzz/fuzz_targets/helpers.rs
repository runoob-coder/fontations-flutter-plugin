//! Deterministic helpers turning fuzz bytes into API arguments, including
//! invalid values that exercise the input guards.

#![allow(dead_code)]

use fontations::api::fontations::VariationSetting;

pub fn glyph_id(data: &[u8]) -> u32 {
    if data.len() >= 2 {
        u16::from_le_bytes([data[0], data[1]]) as u32
    } else {
        0
    }
}

/// Bounded to 64 chars so shaping is actually reached.
pub fn text(data: &[u8]) -> String {
    let sample = &data[..data.len().min(96)];
    String::from_utf8_lossy(sample).chars().take(64).collect()
}

pub fn tag_at(data: &[u8], offset: usize) -> String {
    let end = offset.saturating_add(4).min(data.len());
    if end <= offset || offset >= data.len() {
        return String::new();
    }
    String::from_utf8_lossy(&data[offset..end]).to_string()
}

pub fn variations(data: &[u8]) -> Vec<VariationSetting> {
    let tags = ["wght", "wdth", "slnt", "opsz", "xxxx"];
    let count = (data.first().copied().unwrap_or(0) as usize) % 3;
    (0..count)
        .map(|index| VariationSetting {
            tag: tags[(index + data.get(1).copied().unwrap_or(0) as usize) % tags.len()]
                .to_string(),
            value: data.get(2 + index).copied().unwrap_or(128) as f64 * 8.0 - 1000.0,
        })
        .collect()
}

/// None, a plausible size, NaN and a negative size.
pub fn size(data: &[u8], offset: usize) -> Option<f64> {
    match data.get(offset).copied().unwrap_or(0) % 4 {
        0 => None,
        1 => Some(data.get(offset + 1).copied().unwrap_or(24) as f64 + 1.0),
        2 => Some(f64::NAN),
        _ => Some(-1.0),
    }
}
