// Palette/data-contract invariants that the UI relies on.
import 'package:flutter_test/flutter_test.dart';
import 'package:metro_lisboa_ar/models.dart';

void main() {
  test('lineOrder is exactly the four Metro lines', () {
    expect(lineOrder.toSet(), {'Azul', 'Amarela', 'Verde', 'Vermelha'});
  });

  test('every line has a colour (no fallback-white lines in the UI)', () {
    for (final line in lineOrder) {
      expect(lineColors.containsKey(line), isTrue, reason: '$line is missing from lineColors');
    }
  });

  test('Station.fromJson parses the wire contract', () {
    final s = Station.fromJson(const {
      'stop_id': 'AM',
      'name': 'Alameda',
      'lat': 38.7373,
      'lon': -9.1342,
      'lines': ['Verde', 'Vermelha'],
    });
    expect(s.stopId, 'AM');
    expect(s.name, 'Alameda');
    expect(s.lines, ['Verde', 'Vermelha']);
  });
}
