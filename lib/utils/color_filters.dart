import 'package:flutter/material.dart';

/// カメラプレビュー／フリーズ画面に適用する視認性向上フィルター。
enum ViewFilter {
  none,
  highContrastBw,
  inverted,
  edgeSharpen,
}

extension ViewFilterUi on ViewFilter {
  String get label {
    switch (this) {
      case ViewFilter.none:
        return '通常カラー';
      case ViewFilter.highContrastBw:
        return 'ハイコントラスト白黒';
      case ViewFilter.inverted:
        return 'ネガ反転';
      case ViewFilter.edgeSharpen:
        return '輪郭強調';
    }
  }

  String get shortLabel {
    switch (this) {
      case ViewFilter.none:
        return '通常';
      case ViewFilter.highContrastBw:
        return '白黒';
      case ViewFilter.inverted:
        return 'ネガ';
      case ViewFilter.edgeSharpen:
        return '輪郭';
    }
  }

  IconData get icon {
    switch (this) {
      case ViewFilter.none:
        return Icons.filter_alt_outlined;
      case ViewFilter.highContrastBw:
        return Icons.filter_b_and_w;
      case ViewFilter.inverted:
        return Icons.invert_colors;
      case ViewFilter.edgeSharpen:
        return Icons.auto_fix_high;
    }
  }
}

/// GPU の ColorFilter.matrix 用 5×4 マトリクス定義。
///
/// 白黒・ネガは隣接ピクセルを読まないため ColorMatrix で十分軽い。
/// 輪郭強調は空間フィルタなので [sharpenShaderAsset] を使う。
class ViewColorFilters {
  ViewColorFilters._();

  static const String sharpenShaderAsset = 'shaders/sharpen.frag';

  static const List<double> identity = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ];

  /// 輝度化＋コントラスト強調。レシートや薬箱の薄い印字向け。
  static final List<double> highContrastBw = _grayContrast(2.8);

  /// グレースケール化したうえで白黒反転（黒地に白文字）。
  static final List<double> inverted = _grayContrast(1.6, invert: true);

  /// シェーダー未ロード時のフォールバック。隣接画素は使わずコントラストだけ上げる。
  static final List<double> sharpenFallback = _grayContrast(1.35);

  static List<double> matrixOf(ViewFilter filter) {
    switch (filter) {
      case ViewFilter.none:
        return identity;
      case ViewFilter.highContrastBw:
        return highContrastBw;
      case ViewFilter.inverted:
        return inverted;
      case ViewFilter.edgeSharpen:
        return sharpenFallback;
    }
  }
}

/// out = c * (luma - 128) + 128。invert=true で白黒反転。
List<double> _grayContrast(double c, {bool invert = false}) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  final s = invert ? -c : c;
  final t = invert ? 255 - 128 * (1 - c) : 128 * (1 - c);
  return <double>[
    s * r, s * g, s * b, 0, t, //
    s * r, s * g, s * b, 0, t,
    s * r, s * g, s * b, 0, t,
    0, 0, 0, 1, 0,
  ];
}
