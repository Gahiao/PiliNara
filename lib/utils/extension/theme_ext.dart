import 'package:PiliPlus/utils/bili_colors.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:material_ui/material_ui.dart'
    show ThemeData, Color, ColorScheme, Brightness, Colors;

extension ThemeDataExt on ThemeData {
  bool get isLight => brightness.isLight;

  bool get isDark => brightness.isDark;
}

extension ColorSchemeExt on ColorScheme {
  Color get vipColor =>
      brightness.isLight ? BiliColors.pinkLight : BiliColors.pinkDark;

  Color get blue =>
      brightness.isLight ? BiliColors.blueLight : BiliColors.blueDark;

  Color get btnColor =>
      brightness.isLight ? BiliColors.pinkLight : const Color(0xFF8F0030);

  Color get freeColor =>
      brightness.isLight ? const Color(0xFFFF7F24) : const Color(0xFFD66011);

  bool get isLight => brightness.isLight;

  bool get isDark => brightness.isDark;

  /// 深色主题的 surface 系列整体提亮一档。
  ///
  /// 纯黑背景在 AMOLED 上会把卡片、分割线、次级面板全部压成同一片黑，
  /// 层次完全消失；这里按比例向白混合，保留主题色相的同时保证不会出现
  /// 纯黑（纯黑主题开关仍会在 `ThemeUtils.darkenTheme` 里显式覆盖）。
  ColorScheme get liftedSurface {
    Color lift(Color color) => Color.lerp(color, Colors.white, .07)!;
    return copyWith(
      surface: lift(surface),
      surfaceDim: lift(surfaceDim),
      surfaceBright: lift(surfaceBright),
      surfaceContainerLowest: lift(surfaceContainerLowest),
      surfaceContainerLow: lift(surfaceContainerLow),
      surfaceContainer: lift(surfaceContainer),
      surfaceContainerHigh: lift(surfaceContainerHigh),
      surfaceContainerHighest: lift(surfaceContainerHighest),
    );
  }
}

extension ColorExtension on Color {
  Color darken([double amount = .5]) {
    assert(amount >= 0 && amount <= 1, 'Amount must be between 0 and 1');
    return Color.lerp(this, Colors.black, amount)!;
  }

  ColorScheme asColorSchemeSeed([
    FlexSchemeVariant variant = .material,
    Brightness brightness = .light,
  ]) => SeedColorScheme.fromSeeds(
    primaryKey: this,
    variant: variant,
    brightness: brightness,
    useExpressiveOnContainerColors: false,
  );
}

extension BrightnessExt on Brightness {
  Brightness get reverse => isLight ? Brightness.dark : Brightness.light;

  bool get isLight => this == Brightness.light;

  bool get isDark => this == Brightness.dark;
}
