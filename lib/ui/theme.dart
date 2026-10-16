
import 'package:flutter/material.dart';

import '../core/models/score.dart';

/// Rhytmaniac's palette. Chrome stays in quiet plum-ink; the "heat" ramp is
/// reserved for data — song fingerprints, star ratings, lanes by pitch,
/// judgments — so colour always means energy or difficulty.
abstract final class Palette {
  static const ink = Color(0xFF150D1D);
  static const inkDeep = Color(0xFF0D0712);
  static const surface = Color(0xFF1F1529);
  static const raised = Color(0xFF2A1E36);
  static const line = Color(0xFF3D2F4B);
  static const bone = Color(0xFFF1E9DF);
  static const mist = Color(0xFFA99BB5);
  static const dim = Color(0xFF6C5C7A);

  // Heat ramp, cold to hot.
  static const violet = Color(0xFF3B1C6E);
  static const plum = Color(0xFF7A2382);
  static const rose = Color(0xFFC2366C);
  static const ember = Color(0xFFEE6340);
  static const amber = Color(0xFFFBAF45);
  static const flare = Color(0xFFFDF0A9);

  static const ramp = [violet, plum, rose, ember, amber, flare];

  /// Judgment "Miss": a cool slate so it separates from rose under CVD.
  static const miss = Color(0xFF7A8FB8);

  /// Diverging pair for timing: early (cool) vs late (warm), validated for
  /// colour-vision deficiency against the dark surface.
  static const early = Color(0xFF8E6CF0);
  static const late = ember;

  /// Primary action colour.
  static const action = amber;
  static const onAction = ink;
  static const danger = Color(0xFFFF6B6B);

  /// Samples the heat ramp at [t] (0..1).
  static Color heat(double t) {
    final x = t.clamp(0.0, 1.0) * (ramp.length - 1);
    final i = x.floor().clamp(0, ramp.length - 2);
    return Color.lerp(ramp[i], ramp[i + 1], x - i)!;
  }

  /// Colour for a star rating (1★ cool → 6★ white-hot).
  static Color stars(double s) => heat(0.12 + (s / 6.5) * 0.88);

  static Color judgment(Judgment j) => switch (j) {
        Judgment.perfect => flare,
        Judgment.great => amber,
        Judgment.good => rose,
        Judgment.miss => miss,
      };

  static Color grade(Grade g) => switch (g) {
        Grade.ss => flare,
        Grade.s => amber,
        Grade.a => ember,
        Grade.b => rose,
        Grade.c => plum,
        Grade.d => dim,
        Grade.f => dim,
      };
}

/// Type roles: Anybody (display, variable width — it stretches with play),
/// Instrument Sans (body), Martian Mono (numbers, timings).
abstract final class AppText {
  static TextStyle display(double size, {double width = 120, double weight = 800, Color color = Palette.bone, double? height, double letterSpacing = -0.5}) =>
      TextStyle(
        fontFamily: 'Anybody',
        fontSize: size,
        height: height ?? 1.0,
        letterSpacing: letterSpacing,
        color: color,
        fontWeight: _w(weight),
        fontVariations: [FontVariation.width(width), FontVariation.weight(weight)],
      );

  static TextStyle body(double size, {double weight = 450, Color color = Palette.bone, double height = 1.35}) => TextStyle(
        fontFamily: 'InstrumentSans',
        fontSize: size,
        height: height,
        color: color,
        fontWeight: _w(weight),
        fontVariations: [FontVariation.weight(weight)],
      );

  static TextStyle data(double size, {double weight = 500, Color color = Palette.mist, double letterSpacing = 0}) => TextStyle(
        fontFamily: 'MartianMono',
        fontSize: size,
        height: 1.2,
        letterSpacing: letterSpacing,
        color: color,
        fontWeight: _w(weight),
        fontVariations: [FontVariation.weight(weight), const FontVariation('wdth', 87.5)],
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Small caps-like label for section headers.
  static TextStyle label({Color color = Palette.mist}) =>
      data(10.5, weight: 600, color: color, letterSpacing: 1.4);

  static FontWeight _w(double v) => FontWeight.values[((v / 100).round() - 1).clamp(0, 8)];
}

abstract final class Space {
  static const gutter = 16.0;
  static const radius = 14.0;
  static const radiusSmall = 9.0;
}

ThemeData buildTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Palette.action,
    onPrimary: Palette.onAction,
    secondary: Palette.rose,
    onSecondary: Palette.bone,
    error: Palette.danger,
    onError: Palette.ink,
    surface: Palette.surface,
    onSurface: Palette.bone,
    surfaceContainerHighest: Palette.raised,
    surfaceContainerHigh: Palette.raised,
    surfaceContainer: Palette.surface,
    surfaceContainerLow: Palette.surface,
    surfaceContainerLowest: Palette.ink,
    outline: Palette.line,
    outlineVariant: Palette.line,
    onSurfaceVariant: Palette.mist,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'InstrumentSans');
  return base.copyWith(
    scaffoldBackgroundColor: Palette.ink,
    canvasColor: Palette.ink,
    textTheme: base.textTheme.apply(bodyColor: Palette.bone, displayColor: Palette.bone, fontFamily: 'InstrumentSans'),
    appBarTheme: AppBarTheme(
      backgroundColor: Palette.ink,
      foregroundColor: Palette.bone,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: AppText.display(20, width: 115, weight: 750),
    ),
    dividerTheme: const DividerThemeData(color: Palette.line, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Palette.inkDeep,
      indicatorColor: Palette.raised,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => AppText.body(12, weight: s.contains(WidgetState.selected) ? 650 : 500,
            color: s.contains(WidgetState.selected) ? Palette.bone : Palette.mist),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? Palette.amber : Palette.mist, size: 22),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.action,
        foregroundColor: Palette.onAction,
        minimumSize: const Size(48, 48),
        textStyle: AppText.body(15, weight: 650),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Space.radiusSmall)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.bone,
        side: const BorderSide(color: Palette.line),
        minimumSize: const Size(48, 48),
        textStyle: AppText.body(15, weight: 600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Space.radiusSmall)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Palette.amber, textStyle: AppText.body(14, weight: 600)),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: Palette.amber,
      inactiveTrackColor: Palette.line,
      thumbColor: Palette.amber,
      overlayColor: Color(0x33FBAF45),
      trackHeight: 3,
      showValueIndicator: ShowValueIndicator.never,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Palette.ink : Palette.mist),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Palette.amber : Palette.raised),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Palette.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: Palette.line,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Palette.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: AppText.display(20, width: 110, weight: 750),
      contentTextStyle: AppText.body(14.5, color: Palette.mist),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Palette.raised,
      contentTextStyle: AppText.body(14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Space.radiusSmall)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.raised,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Space.radiusSmall), borderSide: BorderSide.none),
      hintStyle: AppText.body(14, color: Palette.dim),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? Palette.amber.withValues(alpha: 0.16) : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? Palette.amber : Palette.mist),
        side: const WidgetStatePropertyAll(BorderSide(color: Palette.line)),
        textStyle: WidgetStatePropertyAll(AppText.body(13.5, weight: 600)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: Palette.amber, linearTrackColor: Palette.line),
    chipTheme: ChipThemeData(
      backgroundColor: Palette.surface,
      selectedColor: Palette.raised,
      side: const BorderSide(color: Palette.line),
      labelStyle: AppText.body(13, weight: 550),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(40)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
