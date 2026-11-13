#![allow(dead_code)]

/// Deterministic LCG: repeatable inputs, no extra dependency.
pub fn pseudo_random(seed: u64, len: usize) -> Vec<u8> {
    let mut state = seed;
    (0..len)
        .map(|_| {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (state >> 33) as u8
        })
        .collect()
}

/// Byte flips near the header plus truncations of a seed.
pub fn mutations(bytes: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    for index in 0..bytes.len().min(8) {
        for mask in [0x01u8, 0x80] {
            let mut mutated = bytes.to_vec();
            mutated[index] ^= mask;
            out.push(mutated);
        }
    }
    for len in [0, 1, bytes.len() / 2] {
        out.push(bytes[..len].to_vec());
    }
    out
}
