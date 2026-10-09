//! A compact OpenType shaping engine built on `read-fonts`.
//!
//! `skrifa` exposes `GSUB` and `GPOS` as *data*: it will tell you which
//! scripts, languages and features a font declares, but it never applies them.
//! This module fills that gap. It maps a run of text through `cmap`, runs the
//! substitutions and positions of a script / language / feature selection and
//! hands back positioned glyphs.
//!
//! Everything is computed in **font units** and scaled once at the end, so a
//! caller that passes no size gets design units back and one that does gets
//! pixels.
//!
//! It is deliberately not a full HarfBuzz: there is no Unicode character
//! classification (script and language are chosen by the caller), no
//! normalization and no complex cluster splitting. It covers the lookups that
//! carry Latin, Cyrillic and Greek text:
//!
//! * `GSUB` single, multiple, alternate, ligature, reverse chain, and the
//!   contextual and chained contextual lookups (all three formats, including
//!   the nested lookups they trigger);
//! * `GPOS` single, pair, cursive, mark to base, mark to ligature, mark to
//!   mark, and the same two contextual lookups.
//!
//! A lookup's `LookupFlag` decides which glyphs it may touch: the three
//! `Ignore*` flags, and `USE_MARK_FILTERING_SET`, which replaces the `GDEF`
//! glyph classes with a coverage table of the font's choosing.
//!
//! Still missing, and worth knowing before shaping non-Latin text: feature
//! variations, Unicode normalization and cluster splitting, and vertical or
//! right to left runs.

use read_fonts::tables::gdef::{GlyphClassDef, MarkGlyphSets};
use read_fonts::tables::gpos::{
    AnchorTable, CursivePosFormat1, MarkBasePosFormat1, MarkLigPosFormat1, MarkMarkPosFormat1,
    PairPos, PositionLookupList, PositionSubtables, SinglePos, ValueRecord,
};
use read_fonts::tables::gsub::{
    AlternateSubstFormat1, LigatureSubstFormat1, MultipleSubstFormat1, SingleSubst,
    SubstitutionLookupList, SubstitutionSubtables,
};
use read_fonts::tables::layout::{
    ChainedSequenceContext, ClassDef, CoverageTable, DeviceOrVariationIndex, FeatureList,
    LookupFlag, ScriptList, SequenceContext, SequenceLookupRecord,
};
use read_fonts::types::{BigEndian, F2Dot14, GlyphId, Tag};
use read_fonts::{FontRef, ReadError, TableProvider};
use skrifa::instance::LocationRef;
use skrifa::metrics::GlyphMetrics;
use skrifa::prelude::*;

use crate::api::fontations::{ShapeResult, ShapedGlyph};

/// How deeply nested contextual lookups may recurse. Real fonts nest two or
/// three levels; the bound only exists so a malformed font cannot loop.
const MAX_NESTING: u32 = 8;

/// One glyph in the shaping buffer, in font units.
#[derive(Clone, Copy, Debug)]
struct Item {
    glyph: GlyphId,
    /// Index of the character this glyph came from.
    cluster: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
    /// How many glyphs a ligature substitution merged into this one; `0` for
    /// anything else. Mark attachment to a ligature uses it.
    components: usize,
}

/// Everything the lookups need but that never changes while they run.
struct Ctx<'a> {
    upem: f32,
    /// Size in pixels per em, when the caller asked for one. Only device
    /// tables care: they are stored in pixels, not font units.
    ppem: Option<u16>,
    /// Built once. `gdef.glyph_class_def()` resolves an offset and parses the
    /// table on every call, and the shaper asks for a class per glyph while it
    /// attaches marks.
    class_def: Option<ClassDef<'a>>,
    /// Built once: the sets a lookup may point at with
    /// `USE_MARK_FILTERING_SET`.
    mark_sets: Option<MarkGlyphSets<'a>>,
    /// Built once: `glyph_metrics` re-reads `hmtx` (and `HVAR`/`VORG` when the
    /// font has them) on every call, and shaping asks for an advance once per
    /// input character plus once per substitution.
    metrics: GlyphMetrics<'a>,
}

impl<'a> Ctx<'a> {
    /// `font` and `coords` are only needed to build the cached tables; they are
    /// not kept, because the shaper never reaches for either again.
    fn new(font: &'a FontRef<'a>, coords: &'a [F2Dot14], upem: f32, ppem: Option<u16>) -> Self {
        let gdef = font.gdef().ok();
        let class_def = gdef
            .as_ref()
            .and_then(|gdef| gdef.glyph_class_def())
            .and_then(|class_def| class_def.ok());
        let mark_sets = gdef
            .as_ref()
            .and_then(|gdef| gdef.mark_glyph_sets_def())
            .and_then(|sets| sets.ok());
        Self {
            upem,
            ppem,
            class_def,
            mark_sets,
            metrics: font.glyph_metrics(Size::unscaled(), LocationRef::new(coords)),
        }
    }

    fn advance(&self, glyph: GlyphId) -> f32 {
        self.metrics.advance_width(glyph).unwrap_or(0.0)
    }

    /// A device or variation index resolved at the requested size, in font
    /// units. `Device` tables adjust by whole pixels, so an adjustment has to
    /// be converted back into the space the rest of the buffer is in.
    fn device_delta(&self, device: Option<Result<DeviceOrVariationIndex<'a>, ReadError>>) -> f32 {
        let Some(ppem) = self.ppem else {
            return 0.0;
        };
        let pixels = match device {
            Some(Ok(DeviceOrVariationIndex::Device(device))) => device.delta_for_ppem(ppem) as f32,
            _ => 0.0,
        };
        pixels * self.upem / ppem as f32
    }

    /// The `GDEF` class of a glyph, when the font has one.
    fn class(&self, glyph: GlyphId) -> Option<GlyphClassDef> {
        match self.class_def.as_ref()?.get(glyph) {
            1 => Some(GlyphClassDef::Base),
            2 => Some(GlyphClassDef::Ligature),
            3 => Some(GlyphClassDef::Mark),
            4 => Some(GlyphClassDef::Component),
            _ => None,
        }
    }

    /// Whether `glyph` belongs to mark glyph set `index` of `GDEF`.
    ///
    /// `None` when the font has no mark glyph sets at all, or when the index
    /// points past the end: a lookup that names a missing set filters nothing.
    fn in_mark_set(&self, index: u16, glyph: GlyphId) -> Option<bool> {
        let sets = self.mark_sets.as_ref()?;
        let coverage = sets.coverages().get(index as usize).ok()?;
        Some(coverage.get(glyph).is_some())
    }
}

/// Shapes `text` with the given script, language and feature selection.
pub fn shape(font: &FontRef<'_>, text: &str, options: &ShapeOptions<'_>) -> ShapeResult {
    let upem = font
        .metrics(Size::unscaled(), LocationRef::new(options.coords))
        .units_per_em as f32;
    let ctx = Ctx::new(
        font,
        options.coords,
        if upem > 0.0 { upem } else { 1000.0 },
        options.size.map(|size| size as u16),
    );

    // -- cmap -----------------------------------------------------------
    let charmap = font.charmap();
    let mut buffer = Vec::<Item>::with_capacity(text.len());
    for (index, ch) in text.chars().enumerate() {
        let glyph = charmap.map(ch).unwrap_or(GlyphId::NOTDEF);
        buffer.push(Item {
            glyph,
            cluster: index as u32,
            x_advance: ctx.advance(glyph),
            y_advance: 0.0,
            x_offset: 0.0,
            y_offset: 0.0,
            components: 0,
        });
    }

    // -- GSUB -----------------------------------------------------------
    if let Ok(gsub) = font.gsub() {
        let lookups = gsub.lookup_list().ok();
        let features = gsub.feature_list().ok();
        let scripts = gsub.script_list().ok();
        let plan = Plan::new(
            scripts.as_ref(),
            features.as_ref(),
            options.script,
            options.language,
            options.features.as_deref(),
        );
        if let (Some(lookups), Some(features)) = (lookups.as_ref(), features.as_ref()) {
            for index in &plan.features {
                if let Some(feature) = features.feature_records().get(*index as usize) {
                    let data = features.offset_data();
                    if let Ok(feature) = feature.feature(data) {
                        for lookup in feature.lookup_list_indices() {
                            apply_substitution(&mut buffer, lookup.get(), lookups, &ctx, 0);
                        }
                    }
                }
            }
        }
    }

    // -- GPOS -----------------------------------------------------------
    if let Ok(gpos) = font.gpos() {
        let lookups = gpos.lookup_list().ok();
        let features = gpos.feature_list().ok();
        let scripts = gpos.script_list().ok();
        let plan = Plan::new(
            scripts.as_ref(),
            features.as_ref(),
            options.script,
            options.language,
            options.features.as_deref(),
        );
        if let (Some(lookups), Some(features)) = (lookups.as_ref(), features.as_ref()) {
            for index in &plan.features {
                if let Some(feature) = features.feature_records().get(*index as usize) {
                    let data = features.offset_data();
                    if let Ok(feature) = feature.feature(data) {
                        for lookup in feature.lookup_list_indices() {
                            apply_position(&mut buffer, lookup.get(), lookups, &ctx, 0);
                        }
                    }
                }
            }
        }
    }

    // -- out ------------------------------------------------------------
    let scale = match options.size {
        Some(size) => size as f32 / ctx.upem,
        None => 1.0,
    };
    let mut advance = 0.0;
    let glyphs = buffer
        .iter()
        .map(|item| {
            advance += item.x_advance * scale;
            ShapedGlyph {
                glyph_id: item.glyph.to_u32(),
                cluster: item.cluster,
                x_advance: item.x_advance as f64 * scale as f64,
                y_advance: item.y_advance as f64 * scale as f64,
                x_offset: item.x_offset as f64 * scale as f64,
                y_offset: item.y_offset as f64 * scale as f64,
            }
        })
        .collect();

    ShapeResult {
        glyphs,
        advance: advance as f64,
    }
}

/// What to shape and with which features.
pub struct ShapeOptions<'a> {
    pub script: Option<Tag>,
    pub language: Option<Tag>,
    /// The features to turn on. `None` uses the ones that are on by default;
    /// an empty list turns every feature off, which is useful to see what a
    /// font looks like before any of them run.
    pub features: Option<Vec<Tag>>,
    /// Pixels per em. `None` returns font units.
    pub size: Option<f32>,
    /// Normalized variation coordinates.
    pub coords: &'a [F2Dot14],
}

/// Features that are applied unless the caller asks for a specific set.
///
/// The split is the one HarfBuzz makes: the first group is always on, the
/// second only for horizontal text, which is all this shaper does.
const ALWAYS_ON: &[&str] = &["abvm", "blwm", "ccmp", "locl", "mark", "mkmk", "rlig"];
const ON_WHEN_EMPTY: &[&str] = &["calt", "clig", "curs", "dist", "kern", "liga", "rclt"];

/// The feature indices of one layout table, in the order they are applied.
struct Plan {
    features: Vec<u16>,
}

impl Plan {
    /// Picks the script and language system, then keeps every feature the
    /// language system references whose tag is enabled.
    fn new(
        scripts: Option<&ScriptList<'_>>,
        features: Option<&FeatureList<'_>>,
        script: Option<Tag>,
        language: Option<Tag>,
        enabled: Option<&[Tag]>,
    ) -> Plan {
        let mut plan = Plan {
            features: Vec::new(),
        };
        let (Some(scripts), Some(features)) = (scripts, features) else {
            return plan;
        };
        let data = scripts.offset_data();

        // `DFLT` first: it is the fallback every font is supposed to declare,
        // and a caller that knows better passes the script it wants.
        let wanted = script.unwrap_or(Tag::new(b"DFLT"));
        let fallback = Tag::new(b"latn");
        let mut chosen = None;
        for record in scripts.script_records() {
            let tag = record.script_tag();
            if tag == wanted {
                chosen = Some(record);
                break;
            }
            if tag == fallback {
                chosen = Some(record);
            }
        }
        // Nothing matched: take the first script the font declares.
        if chosen.is_none() {
            chosen = scripts.script_records().first();
        }
        let Some(record) = chosen else {
            return plan;
        };
        let Ok(script) = record.script(data) else {
            return plan;
        };

        let mut referenced: Vec<u16> = Vec::new();
        if let Some(Ok(lang_sys)) = script.default_lang_sys() {
            referenced.extend(lang_sys.feature_indices().iter().map(|index| index.get()));
        }
        for lang_record in script.lang_sys_records() {
            let matches = match language {
                Some(wanted) => lang_record.lang_sys_tag() == wanted,
                // Without a request the default language system is the one to
                // use; the others are alternatives for specific languages.
                None => false,
            };
            if matches {
                if let Ok(lang_sys) = lang_record.lang_sys(data) {
                    referenced.extend(lang_sys.feature_indices().iter().map(|i| i.get()));
                }
            }
        }
        // A required feature is applied whatever the caller asked for.
        if let Some(Ok(lang_sys)) = script.default_lang_sys() {
            if lang_sys.required_feature_index() != 0xFFFF {
                referenced.push(lang_sys.required_feature_index());
            }
        }

        // No list at all means the defaults; an empty list means none.
        let enabled = match enabled {
            Some(enabled) => Some(enabled),
            None => None,
        };
        for (index, record) in features.feature_records().iter().enumerate() {
            if !referenced.contains(&(index as u16)) {
                continue;
            }
            let tag = record.feature_tag();
            let on = match enabled {
                None => {
                    let name = format!("{tag}");
                    ALWAYS_ON.contains(&name.as_str()) || ON_WHEN_EMPTY.contains(&name.as_str())
                }
                Some(enabled) => enabled.contains(&tag),
            };
            if on {
                plan.features.push(index as u16);
            }
        }
        plan
    }
}

/// What a lookup is allowed to look at.
///
/// The `Ignore*` flags keep whole classes of glyphs out of a lookup, so a font
/// can position a mark without disturbing the base it sits on. When the lookup
/// also sets `USE_MARK_FILTERING_SET`, "is this a mark?" is answered by a
/// coverage table in `GDEF` instead of by the glyph classes.
#[derive(Clone, Copy, Debug)]
struct Filter {
    flag: LookupFlag,
    /// Index into `GDEF`'s mark glyph sets. Only meaningful together with
    /// `USE_MARK_FILTERING_SET`.
    mark_set: Option<u16>,
}

impl Filter {
    fn new(flag: LookupFlag, mark_set: Option<u16>) -> Self {
        Self { flag, mark_set }
    }

    /// `true` when the glyph at `index` may take part in the lookup.
    fn eligible(&self, buffer: &[Item], index: usize, ctx: &Ctx<'_>) -> bool {
        let Some(item) = buffer.get(index) else {
            return false;
        };
        let class = ctx.class(item.glyph);
        // A filtering set wins over the glyph class: belonging to the set is
        // what makes a glyph a mark for this lookup.
        let is_mark = match self.mark_set {
            Some(set) => ctx.in_mark_set(set, item.glyph).unwrap_or(false),
            None => matches!(class, Some(GlyphClassDef::Mark)),
        };
        if self.flag.contains(LookupFlag::IGNORE_MARKS) && is_mark {
            return false;
        }
        if self.flag.contains(LookupFlag::IGNORE_BASE_GLYPHS)
            && matches!(class, Some(GlyphClassDef::Base) | None)
        {
            return false;
        }
        if self.flag.contains(LookupFlag::IGNORE_LIGATURES)
            && matches!(class, Some(GlyphClassDef::Ligature))
        {
            return false;
        }
        true
    }
}

fn advance_of(buffer: &mut [Item], index: usize, glyph: GlyphId, ctx: &Ctx<'_>) {
    if let Some(item) = buffer.get_mut(index) {
        item.glyph = glyph;
        item.x_advance = ctx.advance(glyph);
    }
}

// ---------------------------------------------------------------------------
// GSUB
// ---------------------------------------------------------------------------

fn apply_substitution(
    buffer: &mut Vec<Item>,
    lookup_index: u16,
    lookups: &SubstitutionLookupList<'_>,
    ctx: &Ctx<'_>,
    depth: u32,
) {
    if depth > MAX_NESTING {
        return;
    }
    let Ok(lookup) = lookups.lookups().get(lookup_index as usize) else {
        return;
    };
    let Ok(subtables) = lookup.subtables() else {
        return;
    };
    let filter = Filter::new(lookup.lookup_flag(), lookup.mark_filtering_set());
    match subtables {
        SubstitutionSubtables::Single(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_single(buffer, &subtable, &filter, ctx);
            }
        }
        SubstitutionSubtables::Multiple(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_multiple(buffer, &subtable, &filter, ctx);
            }
        }
        SubstitutionSubtables::Alternate(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_alternate(buffer, &subtable, &filter, ctx);
            }
        }
        SubstitutionSubtables::Ligature(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_ligature(buffer, &subtable, &filter, ctx);
            }
        }
        SubstitutionSubtables::Reverse(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_reverse(buffer, &subtable, &filter, ctx);
            }
        }
        SubstitutionSubtables::Contextual(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_sequence_context(buffer, &subtable, &filter, ctx, lookups, depth);
            }
        }
        SubstitutionSubtables::ChainContextual(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_chain_context(buffer, &subtable, &filter, ctx, lookups, depth);
            }
        }
        SubstitutionSubtables::EmptyExtension => {}
    }
}

fn apply_single(buffer: &mut [Item], subtable: &SingleSubst<'_>, filter: &Filter, ctx: &Ctx<'_>) {
    let (coverage, delta, glyphs): (
        CoverageTable<'_>,
        Option<i16>,
        &[BigEndian<read_fonts::types::GlyphId16>],
    ) = match subtable {
        SingleSubst::Format1(format) => match format.coverage() {
            Ok(coverage) => (coverage, Some(format.delta_glyph_id()), &[]),
            Err(_) => return,
        },
        SingleSubst::Format2(format) => match format.coverage() {
            Ok(coverage) => (coverage, None, format.substitute_glyph_ids()),
            Err(_) => return,
        },
    };
    for index in 0..buffer.len() {
        if !filter.eligible(buffer, index, ctx) {
            continue;
        }
        let Some(position) = coverage.get(buffer[index].glyph) else {
            continue;
        };
        let replacement = match delta {
            Some(delta) => Some((buffer[index].glyph.to_u32() as i32 + delta as i32) as u32),
            None => glyphs
                .get(position as usize)
                .map(|glyph| glyph.get().to_u32()),
        };
        if let Some(glyph) = replacement {
            advance_of(buffer, index, GlyphId::new(glyph), ctx);
        }
    }
}

fn apply_multiple(
    buffer: &mut Vec<Item>,
    subtable: &MultipleSubstFormat1<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) {
    let Ok(coverage) = subtable.coverage() else {
        return;
    };
    let mut index = 0;
    while index < buffer.len() {
        if !filter.eligible(buffer, index, ctx) {
            index += 1;
            continue;
        }
        let Some(position) = coverage.get(buffer[index].glyph) else {
            index += 1;
            continue;
        };
        let Ok(sequence) = subtable.sequences().get(position as usize) else {
            index += 1;
            continue;
        };
        let glyphs = sequence
            .substitute_glyph_ids()
            .iter()
            .map(|glyph| glyph.get().to_u16())
            .collect::<Vec<_>>();
        if glyphs.is_empty() {
            index += 1;
            continue;
        }
        let template = buffer[index];
        buffer.remove(index);
        for (offset, glyph) in glyphs.iter().enumerate() {
            let glyph = GlyphId::new(*glyph as u32);
            buffer.insert(
                index + offset,
                Item {
                    glyph,
                    cluster: template.cluster,
                    x_advance: ctx.advance(glyph),
                    y_advance: 0.0,
                    x_offset: 0.0,
                    y_offset: 0.0,
                    components: 0,
                },
            );
        }
        index += glyphs.len();
    }
}

fn apply_alternate(
    buffer: &mut [Item],
    subtable: &AlternateSubstFormat1<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) {
    let Ok(coverage) = subtable.coverage() else {
        return;
    };
    for index in 0..buffer.len() {
        if !filter.eligible(buffer, index, ctx) {
            continue;
        }
        let Some(position) = coverage.get(buffer[index].glyph) else {
            continue;
        };
        let Ok(set) = subtable.alternate_sets().get(position as usize) else {
            continue;
        };
        // The first alternate: which one to use is a user choice, and there is
        // no API to express it here.
        let Some(glyph) = set.alternate_glyph_ids().first() else {
            continue;
        };
        advance_of(buffer, index, GlyphId::new(glyph.get().to_u32()), ctx);
    }
}

fn apply_ligature(
    buffer: &mut Vec<Item>,
    subtable: &LigatureSubstFormat1<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) {
    let Ok(coverage) = subtable.coverage() else {
        return;
    };
    let mut index = 0;
    while index < buffer.len() {
        if !filter.eligible(buffer, index, ctx) {
            index += 1;
            continue;
        }
        let Some(position) = coverage.get(buffer[index].glyph) else {
            index += 1;
            continue;
        };
        let Ok(set) = subtable.ligature_sets().get(position as usize) else {
            index += 1;
            continue;
        };
        let mut matched = None;
        for ligature in set.ligatures().iter().flatten() {
            let components = ligature.component_glyph_ids();
            let count = components.len() + 1;
            if index + count > buffer.len() {
                continue;
            }
            let mut fits = true;
            for (offset, component) in components.iter().enumerate() {
                // Every glyph of the sequence has to be eligible, not just the
                // first one: a lookup that ignores marks must not ligate across
                // one, otherwise the mark ends up attached to the ligature.
                let position = index + offset + 1;
                if !filter.eligible(buffer, position, ctx)
                    || buffer[position].glyph != GlyphId::new(component.get().to_u32())
                {
                    fits = false;
                    break;
                }
            }
            if fits {
                matched = Some((ligature.ligature_glyph().to_u32(), count));
                break;
            }
        }
        let Some((glyph, count)) = matched else {
            index += 1;
            continue;
        };
        for _ in 1..count {
            buffer.remove(index + 1);
        }
        if let Some(item) = buffer.get_mut(index) {
            item.glyph = GlyphId::new(glyph);
            // A ligature glyph carries its own advance in `hmtx`.
            item.x_advance = ctx.advance(item.glyph);
            item.components = count;
        }
        index += 1;
    }
}

fn apply_reverse(
    buffer: &mut [Item],
    subtable: &read_fonts::tables::gsub::ReverseChainSingleSubstFormat1<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) {
    let Ok(coverage) = subtable.coverage() else {
        return;
    };
    // Reverse lookups run back to front, which is what lets them see the
    // glyphs before the one they change.
    for index in (0..buffer.len()).rev() {
        if !filter.eligible(buffer, index, ctx) {
            continue;
        }
        let Some(position) = coverage.get(buffer[index].glyph) else {
            continue;
        };
        let backtrack = subtable.backtrack_coverages();
        let lookahead = subtable.lookahead_coverages();
        let mut matches = true;
        for (offset, coverage) in backtrack.iter().enumerate() {
            let Ok(coverage) = coverage else {
                matches = false;
                break;
            };
            if index < offset + 1 || coverage.get(buffer[index - offset - 1].glyph).is_none() {
                matches = false;
                break;
            }
        }
        if matches {
            for (offset, coverage) in lookahead.iter().enumerate() {
                let Ok(coverage) = coverage else {
                    matches = false;
                    break;
                };
                if index + offset + 1 >= buffer.len()
                    || coverage.get(buffer[index + offset + 1].glyph).is_none()
                {
                    matches = false;
                    break;
                }
            }
        }
        if !matches {
            continue;
        }
        let Some(glyph) = subtable.substitute_glyph_ids().get(position as usize) else {
            continue;
        };
        advance_of(buffer, index, GlyphId::new(glyph.get().to_u32()), ctx);
    }
}

/// One match of a contextual lookup: where it starts and which nested lookups
/// it triggers, relative to that start.
struct ContextMatch {
    start: usize,
    records: Vec<SequenceLookupRecord>,
}

fn apply_records(
    buffer: &mut Vec<Item>,
    matches: Vec<ContextMatch>,
    lookups: &SubstitutionLookupList<'_>,
    ctx: &Ctx<'_>,
    depth: u32,
) {
    // Applying from the back keeps the offsets of the matches in front valid
    // even when a nested ligature swallows glyphs.
    let mut matches = matches;
    matches.sort_by(|a, b| b.start.cmp(&a.start));
    for m in matches {
        for record in m.records.iter().rev() {
            let at = m.start + record.sequence_index() as usize;
            if at < buffer.len() {
                apply_substitution(buffer, record.lookup_list_index(), lookups, ctx, depth + 1);
            }
        }
    }
}

fn apply_sequence_context(
    buffer: &mut Vec<Item>,
    subtable: &SequenceContext<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
    lookups: &SubstitutionLookupList<'_>,
    depth: u32,
) {
    let matches = match_sequence_context(buffer, subtable, filter, ctx);
    apply_records(buffer, matches, lookups, ctx, depth);
}

fn match_sequence_context(
    buffer: &[Item],
    subtable: &SequenceContext<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) -> Vec<ContextMatch> {
    let mut out = Vec::new();
    match subtable {
        SequenceContext::Format1(format) => {
            let Ok(coverage) = format.coverage() else {
                return out;
            };
            for start in 0..buffer.len() {
                if !filter.eligible(buffer, start, ctx) {
                    continue;
                }
                let Some(position) = coverage.get(buffer[start].glyph) else {
                    continue;
                };
                let Some(set) = format.seq_rule_sets().get(position as usize) else {
                    continue;
                };
                let Ok(set) = set else {
                    continue;
                };
                for rule in set.seq_rules().iter().flatten() {
                    if let Some(m) = match_glyph_sequence(
                        buffer,
                        start,
                        rule.input_sequence(),
                        rule.seq_lookup_records(),
                    ) {
                        out.push(m);
                        break;
                    }
                }
            }
        }
        SequenceContext::Format2(format) => {
            let (Ok(coverage), Ok(class_def)) = (format.coverage(), format.class_def()) else {
                return out;
            };
            for start in 0..buffer.len() {
                if !filter.eligible(buffer, start, ctx) {
                    continue;
                }
                let Some(position) = coverage.get(buffer[start].glyph) else {
                    continue;
                };
                let Some(set) = format
                    .class_seq_rule_sets()
                    .get(position as usize)
                    .and_then(|set| set.ok())
                else {
                    continue;
                };
                for rule in set.class_seq_rules().iter().flatten() {
                    if let Some(m) = match_class_sequence(
                        buffer,
                        start,
                        rule.input_sequence(),
                        &class_def,
                        rule.seq_lookup_records(),
                    ) {
                        out.push(m);
                        break;
                    }
                }
            }
        }
        SequenceContext::Format3(format) => {
            let coverages = format.coverages();
            let mut sequence = Vec::with_capacity(coverages.len());
            for coverage in coverages.iter() {
                match coverage {
                    Ok(coverage) => sequence.push(coverage),
                    _ => return out,
                }
            }
            for start in 0..buffer.len() {
                if !filter.eligible(buffer, start, ctx) {
                    continue;
                }
                if let Some(m) =
                    match_coverage_sequence(buffer, start, &sequence, format.seq_lookup_records())
                {
                    out.push(m);
                }
            }
        }
    }
    out
}

fn apply_chain_context(
    buffer: &mut Vec<Item>,
    subtable: &ChainedSequenceContext<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
    lookups: &SubstitutionLookupList<'_>,
    depth: u32,
) {
    let matches = match_chain_context(buffer, subtable, filter, ctx);
    apply_records(buffer, matches, lookups, ctx, depth);
}

fn match_chain_context(
    buffer: &[Item],
    subtable: &ChainedSequenceContext<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) -> Vec<ContextMatch> {
    let mut out = Vec::new();
    match subtable {
        ChainedSequenceContext::Format1(format) => {
            let Ok(coverage) = format.coverage() else {
                return out;
            };
            for start in 0..buffer.len() {
                if !filter.eligible(buffer, start, ctx) {
                    continue;
                }
                let Some(position) = coverage.get(buffer[start].glyph) else {
                    continue;
                };
                let Some(set) = format
                    .chained_seq_rule_sets()
                    .get(position as usize)
                    .and_then(|set| set.ok())
                else {
                    continue;
                };
                for rule in set.chained_seq_rules().iter().flatten() {
                    if !match_glyph_run(buffer, start, rule.backtrack_sequence(), true) {
                        continue;
                    }
                    if !match_glyph_run(buffer, start, rule.lookahead_sequence(), false) {
                        continue;
                    }
                    if let Some(m) = match_glyph_sequence(
                        buffer,
                        start,
                        rule.input_sequence(),
                        rule.seq_lookup_records(),
                    ) {
                        out.push(m);
                        break;
                    }
                }
            }
        }
        ChainedSequenceContext::Format2(format) => {
            let (Ok(coverage), Ok(input_classes), Ok(backtrack_classes), Ok(lookahead_classes)) = (
                format.coverage(),
                format.input_class_def(),
                format.backtrack_class_def(),
                format.lookahead_class_def(),
            ) else {
                return out;
            };
            for start in 0..buffer.len() {
                if !filter.eligible(buffer, start, ctx) {
                    continue;
                }
                let Some(position) = coverage.get(buffer[start].glyph) else {
                    continue;
                };
                let Some(set) = format
                    .chained_class_seq_rule_sets()
                    .get(position as usize)
                    .and_then(|set| set.ok())
                else {
                    continue;
                };
                for rule in set.chained_class_seq_rules().iter().flatten() {
                    if !match_class_run(
                        buffer,
                        start,
                        rule.backtrack_sequence(),
                        &backtrack_classes,
                        true,
                    ) {
                        continue;
                    }
                    if !match_class_run(
                        buffer,
                        start,
                        rule.lookahead_sequence(),
                        &lookahead_classes,
                        false,
                    ) {
                        continue;
                    }
                    if let Some(m) = match_class_sequence(
                        buffer,
                        start,
                        rule.input_sequence(),
                        &input_classes,
                        rule.seq_lookup_records(),
                    ) {
                        out.push(m);
                        break;
                    }
                }
            }
        }
        ChainedSequenceContext::Format3(format) => {
            let mut backtrack = Vec::new();
            for coverage in format.backtrack_coverages().iter() {
                match coverage {
                    Ok(coverage) => backtrack.push(coverage),
                    _ => return out,
                }
            }
            let mut input = Vec::new();
            for coverage in format.input_coverages().iter() {
                match coverage {
                    Ok(coverage) => input.push(coverage),
                    _ => return out,
                }
            }
            let mut lookahead = Vec::new();
            for coverage in format.lookahead_coverages().iter() {
                match coverage {
                    Ok(coverage) => lookahead.push(coverage),
                    _ => return out,
                }
            }
            for start in 0..buffer.len() {
                if !filter.eligible(buffer, start, ctx) {
                    continue;
                }
                if !match_coverage_run(buffer, start, &backtrack, true) {
                    continue;
                }
                if !match_coverage_run(buffer, start, &lookahead, false) {
                    continue;
                }
                if let Some(m) =
                    match_coverage_sequence(buffer, start, &input, format.seq_lookup_records())
                {
                    out.push(m);
                }
            }
        }
    }
    out
}

/// Matches `glyphs` (the tail of a rule: the first glyph is the coverage of
/// the rule set) starting at `start`.
fn match_glyph_sequence(
    buffer: &[Item],
    start: usize,
    tail: &[BigEndian<read_fonts::types::GlyphId16>],
    records: &[SequenceLookupRecord],
) -> Option<ContextMatch> {
    let count = tail.len() + 1;
    if start + count > buffer.len() {
        return None;
    }
    for (offset, glyph) in tail.iter().enumerate() {
        if buffer[start + offset + 1].glyph != GlyphId::new(glyph.get().to_u32()) {
            return None;
        }
    }
    Some(ContextMatch {
        start,
        records: records.to_vec(),
    })
}

fn match_class_sequence(
    buffer: &[Item],
    start: usize,
    tail: &[BigEndian<u16>],
    classes: &ClassDef<'_>,
    records: &[SequenceLookupRecord],
) -> Option<ContextMatch> {
    let count = tail.len() + 1;
    if start + count > buffer.len() {
        return None;
    }
    for (offset, class) in tail.iter().enumerate() {
        if classes.get(buffer[start + offset + 1].glyph) != class.get() {
            return None;
        }
    }
    Some(ContextMatch {
        start,
        records: records.to_vec(),
    })
}

fn match_coverage_sequence(
    buffer: &[Item],
    start: usize,
    coverages: &[CoverageTable<'_>],
    records: &[SequenceLookupRecord],
) -> Option<ContextMatch> {
    if coverages.is_empty() || start + coverages.len() > buffer.len() {
        return None;
    }
    for (offset, coverage) in coverages.iter().enumerate() {
        if coverage.get(buffer[start + offset].glyph).is_none() {
            return None;
        }
    }
    Some(ContextMatch {
        start,
        records: records.to_vec(),
    })
}

/// `backtrack` walks the glyphs *before* `start`; `lookahead` the ones after
/// the matched input, which is `start + 1` for these rules.
fn match_glyph_run(
    buffer: &[Item],
    start: usize,
    glyphs: &[BigEndian<read_fonts::types::GlyphId16>],
    backtrack: bool,
) -> bool {
    for (offset, glyph) in glyphs.iter().enumerate() {
        let index = if backtrack {
            start.checked_sub(offset + 1)
        } else {
            Some(start + offset + 1)
        };
        match index {
            Some(index) if index < buffer.len() => {
                if buffer[index].glyph != GlyphId::new(glyph.get().to_u32()) {
                    return false;
                }
            }
            _ => return false,
        }
    }
    true
}

fn match_class_run(
    buffer: &[Item],
    start: usize,
    classes_wanted: &[BigEndian<u16>],
    classes: &ClassDef<'_>,
    backtrack: bool,
) -> bool {
    for (offset, class) in classes_wanted.iter().enumerate() {
        let index = if backtrack {
            start.checked_sub(offset + 1)
        } else {
            Some(start + offset + 1)
        };
        match index {
            Some(index) if index < buffer.len() => {
                if classes.get(buffer[index].glyph) != class.get() {
                    return false;
                }
            }
            _ => return false,
        }
    }
    true
}

fn match_coverage_run(
    buffer: &[Item],
    start: usize,
    coverages: &[CoverageTable<'_>],
    backtrack: bool,
) -> bool {
    for (offset, coverage) in coverages.iter().enumerate() {
        let index = if backtrack {
            start.checked_sub(offset + 1)
        } else {
            Some(start + offset + 1)
        };
        match index {
            Some(index) if index < buffer.len() => {
                if coverage.get(buffer[index].glyph).is_none() {
                    return false;
                }
            }
            _ => return false,
        }
    }
    true
}

// ---------------------------------------------------------------------------
// GPOS
// ---------------------------------------------------------------------------

fn apply_position(
    buffer: &mut Vec<Item>,
    lookup_index: u16,
    lookups: &PositionLookupList<'_>,
    ctx: &Ctx<'_>,
    depth: u32,
) {
    if depth > MAX_NESTING {
        return;
    }
    let Ok(lookup) = lookups.lookups().get(lookup_index as usize) else {
        return;
    };
    let Ok(subtables) = lookup.subtables() else {
        return;
    };
    let filter = Filter::new(lookup.lookup_flag(), lookup.mark_filtering_set());
    match subtables {
        PositionSubtables::Single(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_single_pos(buffer, &subtable, &filter, ctx);
            }
        }
        PositionSubtables::Pair(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_pair_pos(buffer, &subtable, &filter, ctx);
            }
        }
        PositionSubtables::Cursive(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_cursive(buffer, &subtable, &filter, ctx);
            }
        }
        PositionSubtables::MarkToBase(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_mark_to_base(buffer, &subtable, &filter, ctx);
            }
        }
        PositionSubtables::MarkToLig(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_mark_to_lig(buffer, &subtable, &filter, ctx);
            }
        }
        PositionSubtables::MarkToMark(subtables) => {
            for subtable in subtables.iter().flatten() {
                apply_mark_to_mark(buffer, &subtable, &filter, ctx);
            }
        }
        PositionSubtables::Contextual(subtables) => {
            for subtable in subtables.iter().flatten() {
                let matches = match_sequence_context(buffer, &subtable, &filter, ctx);
                apply_pos_records(buffer, matches, lookups, ctx, depth);
            }
        }
        PositionSubtables::ChainContextual(subtables) => {
            for subtable in subtables.iter().flatten() {
                let matches = match_chain_context(buffer, &subtable, &filter, ctx);
                apply_pos_records(buffer, matches, lookups, ctx, depth);
            }
        }
        PositionSubtables::EmptyExtension => {}
    }
}

fn apply_pos_records(
    buffer: &mut Vec<Item>,
    matches: Vec<ContextMatch>,
    lookups: &PositionLookupList<'_>,
    ctx: &Ctx<'_>,
    depth: u32,
) {
    let mut matches = matches;
    matches.sort_by(|a, b| b.start.cmp(&a.start));
    for m in matches {
        for record in m.records.iter().rev() {
            let at = m.start + record.sequence_index() as usize;
            if at < buffer.len() {
                apply_position(buffer, record.lookup_list_index(), lookups, ctx, depth + 1);
            }
        }
    }
}

/// Adds the four components of a `ValueRecord`, resolving its device tables.
fn apply_value(item: &mut Item, record: &ValueRecord<'_>, ctx: &Ctx<'_>) {
    if let Some(value) = record.x_placement() {
        item.x_offset += value as f32 + ctx.device_delta(record.x_placement_device());
    }
    if let Some(value) = record.y_placement() {
        item.y_offset += value as f32 + ctx.device_delta(record.y_placement_device());
    }
    if let Some(value) = record.x_advance() {
        item.x_advance += value as f32 + ctx.device_delta(record.x_advance_device());
    }
    if let Some(value) = record.y_advance() {
        item.y_advance += value as f32 + ctx.device_delta(record.y_advance_device());
    }
}

fn apply_single_pos(buffer: &mut [Item], subtable: &SinglePos<'_>, filter: &Filter, ctx: &Ctx<'_>) {
    let (coverage, records) = match subtable {
        SinglePos::Format1(format) => (format.coverage(), vec![format.value_record()]),
        SinglePos::Format2(format) => (
            format.coverage(),
            format
                .value_records()
                .iter()
                .filter_map(|record| record.ok())
                .collect(),
        ),
    };
    let Ok(coverage) = coverage else {
        return;
    };
    for index in 0..buffer.len() {
        if !filter.eligible(buffer, index, ctx) {
            continue;
        }
        let Some(position) = coverage.get(buffer[index].glyph) else {
            continue;
        };
        if let Some(record) = records.get(position as usize) {
            apply_value(&mut buffer[index], record, ctx);
        }
    }
}

fn apply_pair_pos(buffer: &mut [Item], subtable: &PairPos<'_>, filter: &Filter, ctx: &Ctx<'_>) {
    match subtable {
        PairPos::Format1(format) => {
            let Ok(coverage) = format.coverage() else {
                return;
            };
            for index in 0..buffer.len().saturating_sub(1) {
                if !filter.eligible(buffer, index, ctx) {
                    continue;
                }
                let Some(position) = coverage.get(buffer[index].glyph) else {
                    continue;
                };
                let Ok(set) = format.pair_sets().get(position as usize) else {
                    continue;
                };
                let Some(record) = set.pair_value_records().iter().flatten().find(|record| {
                    GlyphId::new(record.second_glyph().to_u32()) == buffer[index + 1].glyph
                }) else {
                    continue;
                };
                let (first, second) = (record.value_record1(), record.value_record2());
                apply_value(&mut buffer[index], &first, ctx);
                apply_value(&mut buffer[index + 1], &second, ctx);
            }
        }
        PairPos::Format2(format) => {
            let (Ok(coverage), Ok(first_classes), Ok(second_classes)) =
                (format.coverage(), format.class_def1(), format.class_def2())
            else {
                return;
            };
            let records = format.class_value_records();
            for index in 0..buffer.len().saturating_sub(1) {
                if !filter.eligible(buffer, index, ctx) {
                    continue;
                }
                if coverage.get(buffer[index].glyph).is_none() {
                    continue;
                }
                let class1 = first_classes.get(buffer[index].glyph);
                let class2 = second_classes.get(buffer[index + 1].glyph);
                let Some([first, second]) = records.get(class1, class2) else {
                    continue;
                };
                apply_value(&mut buffer[index], &first, ctx);
                apply_value(&mut buffer[index + 1], &second, ctx);
            }
        }
    }
}

fn apply_cursive(
    buffer: &mut [Item],
    subtable: &CursivePosFormat1<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) {
    let Ok(coverage) = subtable.coverage() else {
        return;
    };
    let records = subtable.entry_exit_record();
    let data = subtable.offset_data();
    for index in 0..buffer.len().saturating_sub(1) {
        if !filter.eligible(buffer, index, ctx) {
            continue;
        }
        let Some(position) = coverage.get(buffer[index].glyph) else {
            continue;
        };
        let Some(record) = records.get(position as usize) else {
            continue;
        };
        let (Some(Ok(exit)), Some(entry_position)) = (
            record.exit_anchor(data),
            coverage.get(buffer[index + 1].glyph),
        ) else {
            continue;
        };
        let Some(next) = records.get(entry_position as usize) else {
            continue;
        };
        let Some(Ok(entry)) = next.entry_anchor(data) else {
            continue;
        };
        let (exit_x, exit_y) = anchor_position(&exit, ctx);
        let (entry_x, entry_y) = anchor_position(&entry, ctx);
        // Main direction: stretch or squeeze the advance so the two anchors
        // meet. Only the advance moves; the glyphs themselves stay put.
        buffer[index].x_advance += exit_x - entry_x;
        // Cross stream: the next glyph is shifted, chained through the current
        // offset. `y_advance` must not change - it belongs to vertical layout,
        // and writing it here used to shift every following glyph in a vertical
        // run by the cross stream correction.
        buffer[index + 1].y_offset = buffer[index].y_offset + exit_y - entry_y;
    }
}

/// The anchor position in font units, with its device tables applied.
fn anchor_position(anchor: &AnchorTable<'_>, ctx: &Ctx<'_>) -> (f32, f32) {
    let mut x = anchor.x_coordinate() as f32;
    let mut y = anchor.y_coordinate() as f32;
    if let AnchorTable::Format3(format) = anchor {
        x += ctx.device_delta(format.x_device());
        y += ctx.device_delta(format.y_device());
    }
    (x, y)
}

/// The index of the glyph a mark at `index` attaches to: the closest one
/// before it that is not itself a mark.
fn previous_base(buffer: &[Item], index: usize, ctx: &Ctx<'_>) -> Option<usize> {
    let mut position = index.checked_sub(1)?;
    loop {
        let is_mark = matches!(ctx.class(buffer[position].glyph), Some(GlyphClassDef::Mark));
        if !is_mark {
            return Some(position);
        }
        position = position.checked_sub(1)?;
    }
}

fn apply_mark_to_base(
    buffer: &mut [Item],
    subtable: &MarkBasePosFormat1<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) {
    let (Ok(mark_coverage), Ok(base_coverage), Ok(mark_array), Ok(base_array)) = (
        subtable.mark_coverage(),
        subtable.base_coverage(),
        subtable.mark_array(),
        subtable.base_array(),
    ) else {
        return;
    };
    let class_count = subtable.mark_class_count();
    let mark_data = mark_array.offset_data();
    let base_data = base_array.offset_data();
    for index in 0..buffer.len() {
        let Some(position) = mark_coverage.get(buffer[index].glyph) else {
            continue;
        };
        if !filter.eligible(buffer, index, ctx) {
            continue;
        };
        let Some(record) = mark_array.mark_records().get(position as usize) else {
            continue;
        };
        if record.mark_class() >= class_count {
            continue;
        }
        let Ok(mark_anchor) = record.mark_anchor(mark_data) else {
            continue;
        };
        let Some(base) = previous_base(buffer, index, ctx) else {
            continue;
        };
        if !filter.eligible(buffer, base, ctx) {
            continue;
        };
        let Some(base_position) = base_coverage.get(buffer[base].glyph) else {
            continue;
        };
        let Ok(base_record) = base_array.base_records().get(base_position as usize) else {
            continue;
        };
        let Some(base_anchor) = base_record
            .base_anchors(base_data)
            .get(record.mark_class() as usize)
            .and_then(|anchor| anchor.ok())
        else {
            continue;
        };
        attach(buffer, base, index, &base_anchor, &mark_anchor, ctx);
    }
}

fn apply_mark_to_lig(
    buffer: &mut [Item],
    subtable: &MarkLigPosFormat1<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) {
    let (Ok(mark_coverage), Ok(lig_coverage), Ok(mark_array), Ok(lig_array)) = (
        subtable.mark_coverage(),
        subtable.ligature_coverage(),
        subtable.mark_array(),
        subtable.ligature_array(),
    ) else {
        return;
    };
    let class_count = subtable.mark_class_count();
    let mark_data = mark_array.offset_data();
    let lig_data = lig_array.offset_data();
    for index in 0..buffer.len() {
        let Some(position) = mark_coverage.get(buffer[index].glyph) else {
            continue;
        };
        if !filter.eligible(buffer, index, ctx) {
            continue;
        };
        let Some(record) = mark_array.mark_records().get(position as usize) else {
            continue;
        };
        if record.mark_class() >= class_count {
            continue;
        }
        let Ok(mark_anchor) = record.mark_anchor(mark_data) else {
            continue;
        };
        let Some(base) = previous_base(buffer, index, ctx) else {
            continue;
        };
        if !filter.eligible(buffer, base, ctx) {
            continue;
        };
        let Some(lig_position) = lig_coverage.get(buffer[base].glyph) else {
            continue;
        };
        let Ok(attach_table) = lig_array.ligature_attaches().get(lig_position as usize) else {
            continue;
        };
        let components = attach_table.component_records();
        if components.is_empty() {
            continue;
        }
        // A mark that follows a ligature belongs to its last component, which
        // is where an accent over `fi` sits. HarfBuzz decides this by comparing
        // cluster values; here it is the only sensible default.
        let mut component = components.len() - 1;
        let class = record.mark_class() as usize;
        while component > 0
            && components
                .get(component)
                .ok()
                .and_then(|record| {
                    record
                        .ligature_anchors(lig_data)
                        .get(class)
                        .and_then(|anchor| anchor.ok())
                })
                .is_none()
        {
            component -= 1;
        }
        let Ok(component_record) = components.get(component) else {
            continue;
        };
        let Some(base_anchor) = component_record
            .ligature_anchors(lig_data)
            .get(class)
            .and_then(|anchor| anchor.ok())
        else {
            continue;
        };
        attach(buffer, base, index, &base_anchor, &mark_anchor, ctx);
    }
}

fn apply_mark_to_mark(
    buffer: &mut [Item],
    subtable: &MarkMarkPosFormat1<'_>,
    filter: &Filter,
    ctx: &Ctx<'_>,
) {
    let (Ok(mark1_coverage), Ok(mark2_coverage), Ok(mark1_array), Ok(mark2_array)) = (
        subtable.mark1_coverage(),
        subtable.mark2_coverage(),
        subtable.mark1_array(),
        subtable.mark2_array(),
    ) else {
        return;
    };
    let class_count = subtable.mark_class_count();
    let mark1_data = mark1_array.offset_data();
    let mark2_data = mark2_array.offset_data();
    for index in 0..buffer.len() {
        let Some(position) = mark1_coverage.get(buffer[index].glyph) else {
            continue;
        };
        if !filter.eligible(buffer, index, ctx) {
            continue;
        };
        let Some(record) = mark1_array.mark_records().get(position as usize) else {
            continue;
        };
        if record.mark_class() >= class_count {
            continue;
        }
        let Ok(mark_anchor) = record.mark_anchor(mark1_data) else {
            continue;
        };
        let Some(base) = previous_base(buffer, index, ctx) else {
            continue;
        };
        if !filter.eligible(buffer, base, ctx) {
            continue;
        };
        let Some(base_position) = mark2_coverage.get(buffer[base].glyph) else {
            continue;
        };
        let Ok(base_record) = mark2_array.mark2_records().get(base_position as usize) else {
            continue;
        };
        let Some(base_anchor) = base_record
            .mark2_anchors(mark2_data)
            .get(record.mark_class() as usize)
            .and_then(|anchor| anchor.ok())
        else {
            continue;
        };
        attach(buffer, base, index, &base_anchor, &mark_anchor, ctx);
    }
}

/// Moves the mark so its anchor lands on the base glyph's anchor.
fn attach(
    buffer: &mut [Item],
    base: usize,
    mark: usize,
    base_anchor: &AnchorTable<'_>,
    mark_anchor: &AnchorTable<'_>,
    ctx: &Ctx<'_>,
) {
    let (base_x, base_y) = anchor_position(base_anchor, ctx);
    let (mark_x, mark_y) = anchor_position(mark_anchor, ctx);
    // Marks do not advance: the base glyph already accounts for the space.
    buffer[mark].x_offset = buffer[base].x_offset + base_x - mark_x;
    buffer[mark].y_offset = buffer[base].y_offset + base_y - mark_y;
    buffer[mark].x_advance = 0.0;
    buffer[mark].y_advance = 0.0;
}

#[cfg(test)]
mod bench {
    use super::*;

    /// Not part of the normal suite:
    /// `cargo test --release bench_shape -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn bench_shape_long_text() {
        use crate::api::build::{
            ContourPoint, FontBuildRequest, GlyphSpec, VariationAxisSpec, VariationMaster,
        };

        fn bar(half: f64) -> crate::api::build::GlyphContour {
            crate::api::build::GlyphContour {
                points: vec![
                    ContourPoint {
                        x: 80.0,
                        y: 430.0 - half,
                        on_curve: true,
                    },
                    ContourPoint {
                        x: 920.0,
                        y: 430.0 - half,
                        on_curve: true,
                    },
                    ContourPoint {
                        x: 920.0,
                        y: 430.0 + half,
                        on_curve: true,
                    },
                    ContourPoint {
                        x: 80.0,
                        y: 430.0 + half,
                        on_curve: true,
                    },
                ],
            }
        }

        // 200 glyphs, each with masters that declare an advance, so the font has
        // both `gvar` and `HVAR` - the expensive case for `glyph_metrics`.
        let glyphs = (0u32..200)
            .map(|i| GlyphSpec {
                code_point: 0x4E00 + i,
                contours: vec![bar(20.0)],
                masters: vec![
                    VariationMaster {
                        coordinates: vec![100.0],
                        contours: vec![bar(6.0)],
                        advance_width: Some(600.0),
                        ..Default::default()
                    },
                    VariationMaster {
                        coordinates: vec![900.0],
                        contours: vec![bar(60.0)],
                        advance_width: Some(1200.0),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            })
            .collect();

        let bytes = crate::font_compile::build_ttf(&FontBuildRequest {
            family_name: "Bench".to_string(),
            units_per_em: Some(1000),
            glyphs,
            axes: vec![VariationAxisSpec {
                tag: "wght".to_string(),
                name: "Weight".to_string(),
                min_value: 100.0,
                default_value: 400.0,
                max_value: 900.0,
                ..Default::default()
            }],
            ..Default::default()
        })
        .expect("build");

        let font = FontRef::new(&bytes).expect("parse");
        let text: String = (0u32..200)
            .map(|i| char::from_u32(0x4E00 + i).unwrap())
            .collect::<String>()
            .repeat(3);
        let coords = [F2Dot14::from_f32(1.0)];
        let options = ShapeOptions {
            script: None,
            language: None,
            features: None,
            size: None,
            coords: &coords,
        };

        let iterations = 200;
        let start = std::time::Instant::now();
        let mut total = 0usize;
        for _ in 0..iterations {
            total += shape(&font, &text, &options).glyphs.len();
        }
        let elapsed = start.elapsed();
        println!(
            "shape: {} chars x {} runs = {:?} ({:.1} us/run, {} glyphs)",
            text.chars().count(),
            iterations,
            elapsed,
            elapsed.as_micros() as f64 / iterations as f64,
            total / iterations
        );
    }
}

#[cfg(test)]
mod shape_tests {
    use super::*;
    use crate::api::build::{
        ContourPoint as BuildPoint, FontBuildRequest, GlyphContour, GlyphSpec,
    };
    use crate::api::fontations::Font;
    use read_fonts::types::GlyphId16;
    use read_fonts::FontRef;
    use write_fonts::tables::gdef::{Gdef, MarkGlyphSets};
    use write_fonts::tables::gpos::{
        AnchorTable, BaseArray, BaseRecord, CursivePosFormat1, EntryExitRecord, Gpos, MarkArray,
        MarkBasePosFormat1, MarkRecord, PositionLookup, PositionLookupList,
    };
    use write_fonts::tables::gsub::{
        AlternateSet, AlternateSubstFormat1, Gsub, Ligature, LigatureSet, LigatureSubstFormat1,
        MultipleSubstFormat1, Sequence, SingleSubst, SubstitutionLookup, SubstitutionLookupList,
        SubstitutionSequenceContext,
    };
    use write_fonts::tables::layout::{
        ClassDef, CoverageFormat1, CoverageTable, Feature, FeatureList, FeatureRecord, LangSys,
        Lookup, LookupFlag, Script, ScriptList, ScriptRecord, SequenceContext,
        SequenceContextFormat3, SequenceLookupRecord,
    };
    use write_fonts::{FontBuilder, OffsetMarker};

    // The fixture font has four glyphs, so glyph ids are stable:
    //   A = 1, B = 2, C = 3, D = 4, each one `units_per_em` wide.
    const A: u16 = 1;
    const B: u16 = 2;
    const C: u16 = 3;
    const D: u16 = 4;

    fn box_glyph(code_point: u32) -> GlyphSpec {
        GlyphSpec {
            code_point,
            contours: vec![GlyphContour {
                points: vec![
                    BuildPoint {
                        x: 80.0,
                        y: 400.0,
                        on_curve: true,
                    },
                    BuildPoint {
                        x: 400.0,
                        y: 400.0,
                        on_curve: true,
                    },
                    BuildPoint {
                        x: 400.0,
                        y: 460.0,
                        on_curve: true,
                    },
                    BuildPoint {
                        x: 80.0,
                        y: 460.0,
                        on_curve: true,
                    },
                ],
            }],
            ..Default::default()
        }
    }

    fn base_font() -> Vec<u8> {
        crate::font_compile::build_ttf(&FontBuildRequest {
            family_name: "ShapeFixture".to_string(),
            units_per_em: Some(1000),
            glyphs: vec![
                box_glyph('A' as u32),
                box_glyph('B' as u32),
                box_glyph('C' as u32),
                box_glyph('D' as u32),
            ],
            ..Default::default()
        })
        .expect("build")
    }

    /// Splices freshly built layout tables into the fixture font.
    ///
    /// Everything the request does not name — `glyf`, `cmap`, `hmtx`, ... — is
    /// copied over unchanged, which is the same trick `modify_font` uses.
    fn with_layout(gsub: Option<Gsub>, gpos: Option<Gpos>, gdef: Option<Gdef>) -> Font {
        let base = base_font();
        let font = FontRef::new(&base).expect("parse");
        let mut builder = FontBuilder::new();
        if let Some(table) = &gsub {
            builder.add_table(table).expect("gsub");
        }
        if let Some(table) = &gpos {
            builder.add_table(table).expect("gpos");
        }
        if let Some(table) = &gdef {
            builder.add_table(table).expect("gdef");
        }
        builder.copy_missing_tables(font);
        Font::from_bytes(builder.build(), None).expect("parse")
    }

    fn coverage(glyphs: &[u16]) -> CoverageTable {
        CoverageTable::Format1(CoverageFormat1::new(
            glyphs.iter().map(|gid| GlyphId16::new(*gid)).collect(),
        ))
    }

    fn default_script_list() -> ScriptList {
        ScriptList::new(vec![ScriptRecord::new(
            Tag::new(b"DFLT"),
            Script::new(
                Some(LangSys {
                    required_feature_index: 0xFFFF,
                    feature_indices: vec![0],
                }),
                Vec::new(),
            ),
        )])
    }

    /// One feature, one lookup: enough to exercise a lookup in isolation.
    fn features(tag: &[u8; 4]) -> FeatureList {
        FeatureList::new(vec![FeatureRecord::new(
            Tag::new(tag),
            Feature {
                feature_params: None.into(),
                lookup_list_indices: vec![0],
            },
        )])
    }

    fn gsub_with(lookups: Vec<SubstitutionLookup>) -> Gsub {
        Gsub {
            script_list: OffsetMarker::new(default_script_list()),
            feature_list: OffsetMarker::new(features(b"calt")),
            lookup_list: OffsetMarker::new(SubstitutionLookupList::new(lookups)),
            feature_variations: None.into(),
        }
    }

    fn gpos_with(lookups: Vec<PositionLookup>) -> Gpos {
        Gpos::new(
            default_script_list(),
            features(b"kern"),
            PositionLookupList::new(lookups),
        )
    }

    /// A lookup with the flags (and, optionally, the filtering set) under test.
    fn lookup<T: Default>(subtables: Vec<T>, flag: LookupFlag, mark_set: Option<u16>) -> Lookup<T> {
        let mut lookup = Lookup::new(flag, subtables);
        lookup.mark_filtering_set = mark_set;
        lookup
    }

    fn glyphs_of(font: &Font, text: &str) -> Vec<u32> {
        font.shape(text.to_string(), None, Vec::new(), None, None, None)
            .expect("shape")
            .glyphs
            .iter()
            .map(|glyph| glyph.glyph_id)
            .collect()
    }

    #[test]
    fn multiple_substitution_expands_one_glyph_into_many() {
        let font = with_layout(
            Some(gsub_with(vec![SubstitutionLookup::Multiple(lookup(
                vec![MultipleSubstFormat1::new(
                    coverage(&[A]),
                    vec![Sequence::new(vec![GlyphId16::new(B), GlyphId16::new(C)])],
                )],
                LookupFlag::empty(),
                None,
            ))])),
            None,
            None,
        );

        assert_eq!(glyphs_of(&font, "A"), [2, 3]);
        // Two advances, so the run is twice as wide.
        assert_eq!(
            font.shape("A".to_string(), None, Vec::new(), None, None, None)
                .unwrap()
                .advance,
            2000.0
        );
    }

    #[test]
    fn alternate_substitution_picks_the_first_alternate() {
        let font = with_layout(
            Some(gsub_with(vec![SubstitutionLookup::Alternate(lookup(
                vec![AlternateSubstFormat1::new(
                    coverage(&[A]),
                    vec![AlternateSet::new(vec![
                        GlyphId16::new(D),
                        GlyphId16::new(B),
                    ])],
                )],
                LookupFlag::empty(),
                None,
            ))])),
            None,
            None,
        );

        assert_eq!(glyphs_of(&font, "A"), [4]);
    }

    #[test]
    fn ligature_substitution_merges_a_sequence() {
        let font = with_layout(
            Some(gsub_with(vec![SubstitutionLookup::Ligature(lookup(
                vec![LigatureSubstFormat1::new(
                    coverage(&[A]),
                    vec![LigatureSet::new(vec![Ligature::new(
                        GlyphId16::new(D),
                        vec![GlyphId16::new(B)],
                    )])],
                )],
                LookupFlag::empty(),
                None,
            ))])),
            None,
            None,
        );

        assert_eq!(glyphs_of(&font, "AB"), [4]);
        // A on its own has nothing to ligate with.
        assert_eq!(glyphs_of(&font, "A"), [1]);
    }

    #[test]
    fn a_ligature_does_not_reach_across_an_ignored_glyph() {
        // `B` is a mark, and the lookup ignores marks, so "AB" must not ligate
        // even though the sequence matches.
        let gdef = {
            let mut gdef = Gdef::new(
                Some(ClassDef::format_1(GlyphId16::new(A), vec![1, 3])),
                None,
                None,
                None,
            );
            gdef.mark_glyph_sets_def = None.into();
            gdef
        };

        let ligature = |flag: LookupFlag| {
            with_layout(
                Some(gsub_with(vec![SubstitutionLookup::Ligature(lookup(
                    vec![LigatureSubstFormat1::new(
                        coverage(&[A]),
                        vec![LigatureSet::new(vec![Ligature::new(
                            GlyphId16::new(D),
                            vec![GlyphId16::new(B)],
                        )])],
                    )],
                    flag,
                    None,
                ))])),
                None,
                Some(gdef.clone()),
            )
        };

        assert_eq!(glyphs_of(&ligature(LookupFlag::empty()), "AB"), [4]);
        assert_eq!(
            glyphs_of(&ligature(LookupFlag::IGNORE_MARKS), "AB"),
            [1, 2],
            "a mark in the sequence must stop the ligature"
        );
    }

    #[test]
    fn mark_filtering_set_decides_what_counts_as_a_mark() {
        // `B` is a base glyph as far as the class definition is concerned, but
        // the lookup names a filtering set that contains it.
        let gdef = {
            let mut gdef = Gdef::new(
                Some(ClassDef::format_1(GlyphId16::new(A), vec![1, 1])),
                None,
                None,
                None,
            );
            gdef.mark_glyph_sets_def = Some(MarkGlyphSets::new(vec![coverage(&[B])])).into();
            gdef
        };

        let substitute = |mark_set: Option<u16>| {
            with_layout(
                Some(gsub_with(vec![SubstitutionLookup::Single(lookup(
                    vec![SingleSubst::format_2(
                        coverage(&[B]),
                        vec![GlyphId16::new(D)],
                    )],
                    LookupFlag::IGNORE_MARKS | LookupFlag::USE_MARK_FILTERING_SET,
                    mark_set,
                ))])),
                None,
                Some(gdef.clone()),
            )
        };

        // The set says `B` is a mark, so `IgnoreMarks` skips it.
        assert_eq!(glyphs_of(&substitute(Some(0)), "B"), [2]);
        // A set that does not exist filters nothing, so `B` is substituted.
        assert_eq!(glyphs_of(&substitute(Some(9)), "B"), [4]);
    }

    #[test]
    fn cursive_attachment_moves_the_advance_and_the_cross_stream_offset() {
        // A exits at (100, 50), B enters at (20, 10).
        let font = with_layout(
            None,
            Some(gpos_with(vec![PositionLookup::Cursive(lookup(
                vec![CursivePosFormat1::new(
                    coverage(&[A, B]),
                    vec![
                        EntryExitRecord::new(
                            Some(AnchorTable::format_1(0, 0)),
                            Some(AnchorTable::format_1(100, 50)),
                        ),
                        EntryExitRecord::new(Some(AnchorTable::format_1(20, 10)), None),
                    ],
                )],
                LookupFlag::empty(),
                None,
            ))])),
            None,
        );

        let result = font
            .shape("AB".to_string(), None, Vec::new(), None, None, None)
            .expect("shape");
        // Main direction: the advance grows so the two anchors meet.
        assert_eq!(result.glyphs[0].x_advance, 1080.0);
        // Cross stream: the next glyph is shifted ...
        assert_eq!(result.glyphs[1].y_offset, 40.0);
        // ... and the vertical advance is left alone. It belongs to vertical
        // layout; writing the cross stream correction into it used to move
        // every following glyph of a vertical run.
        assert_eq!(result.glyphs[0].y_advance, 0.0);
        assert_eq!(result.glyphs[1].y_advance, 0.0);
    }

    #[test]
    fn mark_to_base_attaches_a_mark_to_its_base() {
        // `A` is a base, `B` is a mark.
        let mut gdef = Gdef::new(
            Some(ClassDef::format_1(GlyphId16::new(A), vec![1, 3])),
            None,
            None,
            None,
        );
        gdef.mark_glyph_sets_def = None.into();

        let font = with_layout(
            None,
            Some(gpos_with(vec![PositionLookup::MarkToBase(lookup(
                vec![MarkBasePosFormat1::new(
                    coverage(&[B]),
                    coverage(&[A]),
                    MarkArray::new(vec![MarkRecord::new(0, AnchorTable::format_1(10, 20))]),
                    BaseArray::new(vec![BaseRecord::new(vec![Some(AnchorTable::format_1(
                        100, 200,
                    ))])]),
                )],
                LookupFlag::empty(),
                None,
            ))])),
            Some(gdef),
        );

        let result = font
            .shape("AB".to_string(), None, Vec::new(), None, None, None)
            .expect("shape");
        // The mark sits where its anchor meets the base's anchor ...
        assert_eq!(result.glyphs[1].x_offset, 90.0);
        assert_eq!(result.glyphs[1].y_offset, 180.0);
        // ... and contributes no advance of its own.
        assert_eq!(result.glyphs[1].x_advance, 0.0);
    }

    #[test]
    fn a_contextual_lookup_runs_its_nested_lookup() {
        // Lookup 0: "when the input is A, run lookup 1". Lookup 1: A -> D.
        let font = with_layout(
            Some(gsub_with(vec![
                SubstitutionLookup::Contextual(lookup(
                    vec![SequenceContext::Format3(SequenceContextFormat3::new(
                        vec![coverage(&[A])],
                        vec![SequenceLookupRecord::new(0, 1)],
                    ))
                    .into()],
                    LookupFlag::empty(),
                    None,
                )),
                SubstitutionLookup::Single(lookup(
                    vec![SingleSubst::format_2(
                        coverage(&[A]),
                        vec![GlyphId16::new(D)],
                    )],
                    LookupFlag::empty(),
                    None,
                )),
            ])),
            None,
            None,
        );

        assert_eq!(glyphs_of(&font, "A"), [4]);
        // The context does not match `B`, so nothing happens.
        assert_eq!(glyphs_of(&font, "B"), [2]);
    }
}
