import 'package:flutter_test/flutter_test.dart';
import 'package:magnifier_mvp/utils/color_filters.dart';

void main() {
  test('each filter exposes a 5x4 color matrix', () {
    for (final filter in ViewFilter.values) {
      expect(ViewColorFilters.matrixOf(filter), hasLength(20));
    }
  });

  test('none uses identity and invert differs from high-contrast', () {
    expect(ViewColorFilters.matrixOf(ViewFilter.none), ViewColorFilters.identity);
    expect(
      ViewColorFilters.matrixOf(ViewFilter.highContrastBw),
      isNot(equals(ViewColorFilters.matrixOf(ViewFilter.inverted))),
    );
  });

  test('cycle order is none → B&W → invert → sharpen', () {
    expect(ViewFilter.values.map((e) => e.name).toList(), [
      'none',
      'highContrastBw',
      'inverted',
      'edgeSharpen',
    ]);
  });
}
