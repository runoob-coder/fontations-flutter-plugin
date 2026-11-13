// Shared fixtures; no Rust library calls.
library;

import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fontations/fontations.dart';

// --- Font bytes -------------------------------------------------------------

/// Inter.ttf, relative to the package root.
Uint8List interBytes() =>
    File('example/assets/fonts/Inter.ttf').readAsBytesSync();

// --- Path elements ----------------------------------------------------------

PathElement pathElement(PathVerb verb, List<double> points) =>
    PathElement(verb: verb, points: Float64List.fromList(points));

/// A 10 x 10 right triangle at the origin (y up).
List<PathElement> triangle() => <PathElement>[
  pathElement(PathVerb.moveTo, <double>[0, 0]),
  pathElement(PathVerb.lineTo, <double>[10, 10]),
  pathElement(PathVerb.lineTo, <double>[0, 10]),
  pathElement(PathVerb.close, <double>[]),
];

// --- Colour glyphs ----------------------------------------------------------

ColorStop colorStop(double offset, int color) =>
    ColorStop(offset: offset, color: color, alpha: 1);

ColorPaint solidPaint({int color = 0xFF112233, double alpha = 1}) => ColorPaint(
  kind: PaintKind.solid,
  color: color,
  alpha: alpha,
  x0: 0,
  y0: 0,
  x1: 0,
  y1: 0,
  r0: 0,
  r1: 0,
  startAngle: 0,
  endAngle: 0,
  extend: 'pad',
  stops: const <ColorStop>[],
);

ColorPaint gradientPaint({
  required PaintKind kind,
  List<ColorStop>? stops,
  String extend = 'pad',
  double x0 = 0,
  double y0 = 0,
  double x1 = 100,
  double y1 = 100,
  double r0 = 0,
  double r1 = 50,
  double startAngle = 0,
  double endAngle = 360,
}) => ColorPaint(
  kind: kind,
  color: 0xFF112233,
  alpha: 1,
  x0: x0,
  y0: y0,
  x1: x1,
  y1: y1,
  r0: r0,
  r1: r1,
  startAngle: startAngle,
  endAngle: endAngle,
  extend: extend,
  stops:
      stops ?? <ColorStop>[colorStop(0, 0xFFFF0000), colorStop(1, 0xFF0000FF)],
);

ColorLayer colorLayer({
  List<PathElement>? elements,
  ColorPaint? paint,
  String composite = 'SrcOver',
}) => ColorLayer(
  elements: elements ?? triangle(),
  paint: paint ?? solidPaint(),
  composite: composite,
);

ColorGlyphInfo colorGlyph(
  List<ColorLayer> layers, {
  String format = 'colrV1',
  RectF? bounds,
}) => ColorGlyphInfo(format: format, bounds: bounds, layers: layers);

// --- Outlines ---------------------------------------------------------------

ScalerInfo scalerInfo({
  bool isHinted = false,
  String dropoutControl = 'simple',
}) => ScalerInfo(isHinted: isHinted, dropoutControl: dropoutControl);

GlyphOutline glyphOutline({
  List<PathElement>? elements,
  RectF? bounds,
  double? advanceWidth,
}) => GlyphOutline(
  elements: elements ?? triangle(),
  bounds: bounds,
  advanceWidth: advanceWidth,
  hasHinting: false,
  hasOverlaps: false,
  scaler: scalerInfo(),
);

// --- Recording canvas -------------------------------------------------------

/// A recorded `drawPath` call.
class RecordedDraw {
  const RecordedDraw(this.path, this.paint);

  final ui.Path path;
  final ui.Paint paint;
}

/// Records the painter's canvas calls; `noSuchMethod` supplies the rest.
class RecordingCanvas implements ui.Canvas {
  final List<RecordedDraw> draws = <RecordedDraw>[];
  final List<ui.BlendMode> layerBlendModes = <ui.BlendMode>[];
  int restoreCount = 0;

  @override
  void drawPath(ui.Path path, ui.Paint paint) {
    draws.add(RecordedDraw(path, paint));
  }

  @override
  void saveLayer(ui.Rect? bounds, ui.Paint paint) {
    layerBlendModes.add(paint.blendMode);
  }

  @override
  void restore() => restoreCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// --- Font build requests ----------------------------------------------------

/// An 840 x 60 bar.
GlyphContour bar(double y) => GlyphContour(
  points: <ContourPoint>[
    ContourPoint(x: 80, y: y - 30, onCurve: true),
    ContourPoint(x: 920, y: y - 30, onCurve: true),
    ContourPoint(x: 920, y: y + 30, onCurve: true),
    ContourPoint(x: 80, y: y + 30, onCurve: true),
  ],
);

GlyphSpec glyphSpec(int codePoint, {double? advanceWidth}) => GlyphSpec(
  codePoint: codePoint,
  contours: <GlyphContour>[bar(430)],
  advanceWidth: advanceWidth,
  masters: const <VariationMaster>[],
  alternates: const <StylisticAlternate>[],
  components: const <GlyphComponent>[],
  colorLayers: const <GlyphColorLayer>[],
);

FontBuildRequest buildRequest({
  String familyName = 'Test',
  int? unitsPerEm = 1000,
  double? ascender,
  double? descender,
  List<GlyphSpec> glyphs = const <GlyphSpec>[],
  List<KernPair> kernPairs = const <KernPair>[],
}) => FontBuildRequest(
  familyName: familyName,
  unitsPerEm: unitsPerEm,
  ascender: ascender,
  descender: descender,
  glyphs: glyphs,
  axes: const <VariationAxisSpec>[],
  instances: const <NamedInstanceSpec>[],
  kernPairs: kernPairs,
  ligatures: const <LigatureSpec>[],
  rawTables: const <RawTableSpec>[],
  variationSelectors: const <VariationSelectorSpec>[],
  palette: Uint32List(0),
);

FontModificationRequest modificationRequest({
  String? familyName,
  List<KernPair> kernPairs = const <KernPair>[],
}) => FontModificationRequest(
  familyName: familyName,
  kernPairs: kernPairs,
  ligatures: const <ExistingLigatureSpec>[],
  alternates: const <ExistingAlternateSpec>[],
);
