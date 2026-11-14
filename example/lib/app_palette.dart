import 'package:material_ui/material_ui.dart';

/// The six fills of `googlefonts.svg`.
class GoogleFontsColors {
  const GoogleFontsColors._();

  // --- SVG fills -----------------------------------------------------------
  static const Color blue = Color(0xFF1A73E8);
  static const Color deepBlue = Color(0xFF174EA6);
  static const Color green = Color(0xFF34A853);
  static const Color deepGreen = Color(0xFF0D652D);
  static const Color amber = Color(0xFFF29900);
  static const Color red = Color(0xFFEA4335);

  // --- lighter tonal stops for dark surfaces -------------------------------
  static const Color blueLight = Color(0xFF8AB4F8);
  static const Color deepBlueLight = Color(0xFFA8C7FA);
  static const Color greenLight = Color(0xFF81C995);
  static const Color amberLight = Color(0xFFFDD663);
  static const Color redLight = Color(0xFFF28B82);

  // --- tonal containers paired with the fills ------------------------------
  static const Color onBlueDark = Color(0xFF062E6F);
  static const Color blueContainer = Color(0xFFD2E3FC);
  static const Color blueContainerDark = Color(0xFF0842A0);
  static const Color onBlueContainer = Color(0xFF041E49);
  static const Color deepBlueContainerDark = Color(0xFF174EA6);
  static const Color greenContainer = Color(0xFFCEEAD6);
  static const Color greenContainerDark = Color(0xFF1E4625);
  static const Color redContainer = Color(0xFFFCE8E6);
  static const Color redContainerDark = Color(0xFF8C1D18);
  static const Color onRedContainer = Color(0xFF601410);
  static const Color onRedContainerDark = Color(0xFFF9DEDC);
}

/// One accent per demo page, in navigation order.
@immutable
class BrandColors extends ThemeExtension<BrandColors> {
  const BrandColors(this.accents);

  final List<Color> accents;

  static const Color _inkShade = Color(0x59000000);

  // --- palettes ------------------------------------------------------------
  static const BrandColors light = BrandColors([
    GoogleFontsColors.blue,
    GoogleFontsColors.green,
    GoogleFontsColors.amber,
    GoogleFontsColors.deepBlue,
    GoogleFontsColors.red,
  ]);

  static const BrandColors dark = BrandColors([
    GoogleFontsColors.blueLight,
    GoogleFontsColors.greenLight,
    GoogleFontsColors.amberLight,
    GoogleFontsColors.deepBlueLight,
    GoogleFontsColors.redLight,
  ]);

  static BrandColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<BrandColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  /// Accent darkened for contrast on light surfaces.
  Color ink(BuildContext context, int index) {
    final accent = accents[index];
    if (Theme.of(context).brightness == Brightness.dark) return accent;
    return Color.alphaBlend(_inkShade, accent);
  }

  Color tint(BuildContext context, int index) {
    final scheme = Theme.of(context).colorScheme;
    final alpha = scheme.brightness == Brightness.light ? 0.20 : 0.32;
    return Color.alphaBlend(
      accents[index].withValues(alpha: alpha),
      scheme.surfaceContainerHighest,
    );
  }

  @override
  BrandColors copyWith({List<Color>? accents}) =>
      BrandColors(accents ?? this.accents);

  @override
  ThemeExtension<BrandColors> lerp(
    covariant ThemeExtension<BrandColors>? other,
    double t,
  ) {
    if (other is! BrandColors) return this;
    return BrandColors([
      for (var i = 0; i < accents.length; i++)
        Color.lerp(accents[i], other.accents[i], t)!,
    ]);
  }
}

/// Seed-derived neutrals plus the exact logo colors for the identity roles.
ColorScheme _brandScheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  return ColorScheme.fromSeed(
    seedColor: GoogleFontsColors.blue,
    brightness: brightness,
  ).copyWith(
    primary: light ? GoogleFontsColors.blue : GoogleFontsColors.blueLight,
    onPrimary: light ? const Color(0xFFFFFFFF) : GoogleFontsColors.onBlueDark,
    primaryContainer: light
        ? GoogleFontsColors.blueContainer
        : GoogleFontsColors.blueContainerDark,
    onPrimaryContainer: light
        ? GoogleFontsColors.onBlueContainer
        : GoogleFontsColors.blueContainer,
    secondary: light
        ? GoogleFontsColors.deepBlue
        : GoogleFontsColors.deepBlueLight,
    onSecondary: light ? const Color(0xFFFFFFFF) : GoogleFontsColors.onBlueDark,
    secondaryContainer: light
        ? GoogleFontsColors.blueContainer
        : GoogleFontsColors.deepBlueContainerDark,
    onSecondaryContainer: light
        ? GoogleFontsColors.onBlueContainer
        : GoogleFontsColors.blueContainer,
    tertiary: light
        ? GoogleFontsColors.deepGreen
        : GoogleFontsColors.greenLight,
    onTertiary: light ? const Color(0xFFFFFFFF) : GoogleFontsColors.deepGreen,
    tertiaryContainer: light
        ? GoogleFontsColors.greenContainer
        : GoogleFontsColors.greenContainerDark,
    onTertiaryContainer: light
        ? GoogleFontsColors.deepGreen
        : GoogleFontsColors.greenContainer,
    error: light ? GoogleFontsColors.red : GoogleFontsColors.redLight,
    onError: light ? const Color(0xFFFFFFFF) : GoogleFontsColors.onRedContainer,
    errorContainer: light
        ? GoogleFontsColors.redContainer
        : GoogleFontsColors.redContainerDark,
    onErrorContainer: light
        ? GoogleFontsColors.onRedContainer
        : GoogleFontsColors.onRedContainerDark,
  );
}

/// Light and dark themes for the example app.
ThemeData appTheme(Brightness brightness) {
  final scheme = _brandScheme(brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    extensions: <ThemeExtension<dynamic>>[
      brightness == Brightness.light ? BrandColors.light : BrandColors.dark,
    ],
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: scheme.primaryContainer,
    ),
    navigationRailTheme: NavigationRailThemeData(
      indicatorColor: scheme.primaryContainer,
    ),
  );
}
