import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_shaders/flutter_shaders.dart';

import '../utils/color_filters.dart';

/// プレビュー／フリーズ画像に視認性フィルターを載せる。
///
/// 通常・白黒・ネガは [ColorFiltered]（コンポジタ上の ColorMatrix）のみ。
/// 輪郭強調だけフラグメントシェーダーを使い、他モードではサンプリングしない。
class VisibilityFilterLayer extends StatelessWidget {
  const VisibilityFilterLayer({
    super.key,
    required this.filter,
    required this.child,
  });

  final ViewFilter filter;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    switch (filter) {
      case ViewFilter.none:
        return child;
      case ViewFilter.highContrastBw:
      case ViewFilter.inverted:
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(ViewColorFilters.matrixOf(filter)),
          child: child,
        );
      case ViewFilter.edgeSharpen:
        return ShaderBuilder(
          (BuildContext context, ui.FragmentShader shader, Widget? child) {
            return AnimatedSampler(
              (ui.Image image, Size size, Canvas canvas) {
                shader.setFloat(0, size.width);
                shader.setFloat(1, size.height);
                shader.setImageSampler(0, image);
                canvas.drawRect(
                  Offset.zero & size,
                  Paint()..shader = shader,
                );
              },
              child: child!,
            );
          },
          assetKey: ViewColorFilters.sharpenShaderAsset,
          child: child,
        );
    }
  }
}
