//! Ceilings on untrusted font input, kept in one place for review. They are
//! conservative: a well formed font never comes close to any of them.

use std::cell::Cell;

use anyhow::{anyhow, Result};

/// Largest accepted font file, leaving room for big CJK and variable fonts.
pub const MAX_FONT_BYTES: usize = 64 * 1024 * 1024;

/// Largest text run accepted by `Font::shape`.
pub const MAX_SHAPE_CHARS: usize = 65_536;

/// Largest number of variation settings per call.
pub const MAX_VARIATION_SETTINGS: usize = 64;

/// Largest number of `VARC` components resolved for one glyph.
pub const MAX_VARC_COMPONENTS: usize = 4_096;

/// Largest number of axis indices / values reported for one `VARC` component.
pub const MAX_VARC_AXES: usize = 256;

/// Maximum `VARC` condition nesting; also stops cyclic conditions.
pub const MAX_CONDITION_DEPTH: u32 = 8;

/// Total condition nodes visited for one `VARC` glyph, across all components.
pub const MAX_CONDITION_NODES: u32 = 4_096;

/// Largest number of `COLR` layers handed to Dart for one glyph.
pub const MAX_COLOR_LAYERS: usize = 2_048;

/// Largest transform stack of a `COLR` paint graph.
pub const MAX_TRANSFORM_DEPTH: usize = 64;

/// Bounds buffer length x lookup count x nested lookups for one `shape()`.
pub const MAX_SHAPE_OPERATIONS: u32 = 4_000_000;

/// Rejects font bytes that are too large to hand to the parser.
pub fn check_font_bytes(bytes: &[u8]) -> Result<()> {
    if bytes.len() > MAX_FONT_BYTES {
        return Err(anyhow!(
            "font is too large: {} bytes (limit {})",
            bytes.len(),
            MAX_FONT_BYTES
        ));
    }
    Ok(())
}

/// Interior-mutable work budget for one shaping call (`Ctx` is shared).
#[derive(Debug)]
pub struct WorkBudget {
    remaining: Cell<u32>,
}

impl WorkBudget {
    pub fn new(limit: u32) -> Self {
        Self {
            remaining: Cell::new(limit),
        }
    }

    /// Spends `amount`; pins the budget at zero when it would underflow.
    pub fn spend(&self, amount: u32) -> bool {
        let left = self.remaining.get();
        if left == 0 {
            return false;
        }
        match left.checked_sub(amount) {
            Some(rest) => {
                self.remaining.set(rest);
                true
            }
            None => {
                self.remaining.set(0);
                false
            }
        }
    }

    pub fn exhausted(&self) -> bool {
        self.remaining.get() == 0
    }
}

/// Nodes visited while evaluating the conditions of one `VARC` glyph.
#[derive(Debug, Default)]
pub struct ConditionBudget {
    nodes: u32,
}

impl ConditionBudget {
    pub fn spend(&mut self) -> bool {
        if self.nodes >= MAX_CONDITION_NODES {
            return false;
        }
        self.nodes += 1;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn font_bytes_are_bounded() {
        assert!(check_font_bytes(&vec![0; MAX_FONT_BYTES]).is_ok());
        let err = check_font_bytes(&vec![0; MAX_FONT_BYTES + 1]).unwrap_err();
        assert!(err.to_string().contains("too large"), "{err}");
    }

    #[test]
    fn work_budget_stops_and_stays_at_zero() {
        let budget = WorkBudget::new(10);
        assert!(budget.spend(6));
        assert!(budget.spend(4));
        assert!(budget.exhausted());
        assert!(!budget.spend(1));
        assert!(budget.exhausted());
        assert!(!budget.spend(0));
    }

    #[test]
    fn condition_budget_is_shared_across_components() {
        let mut budget = ConditionBudget::default();
        for _ in 0..MAX_CONDITION_NODES {
            assert!(budget.spend());
        }
        assert!(!budget.spend());
        assert!(!budget.spend());
    }
}
