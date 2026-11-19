import 'package:flutter_test/flutter_test.dart';
import 'package:magnifier_mvp/utils/color_filters.dart';

void main() {
  test('visibility filters expose four modes', () {
    expect(ViewFilter.values, hasLength(4));
    expect(ViewFilter.none.label, isNotEmpty);
    expect(ViewFilter.edgeSharpen.icon, isNotNull);
  });
}
