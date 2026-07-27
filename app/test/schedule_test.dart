// Service-window logic — the boundaries that decide "Metro closed" vs. live.
import 'package:flutter_test/flutter_test.dart';
import 'package:metro_lisboa_ar/schedule.dart';

void main() {
  DateTime at(int h, int m) => DateTime(2026, 7, 19, h, m);

  group('metroClosedAt (service 06:30–01:00)', () {
    test('open during service hours', () {
      expect(metroClosedAt(at(6, 30)), isFalse); // first trains
      expect(metroClosedAt(at(8, 0)), isFalse);
      expect(metroClosedAt(at(23, 59)), isFalse);
      // past midnight the metro is still running until 01:00
      expect(metroClosedAt(at(0, 30)), isFalse);
      expect(metroClosedAt(at(0, 59)), isFalse);
    });

    test('closed overnight', () {
      expect(metroClosedAt(at(1, 0)), isTrue); // last train has gone
      expect(metroClosedAt(at(3, 0)), isTrue);
      expect(metroClosedAt(at(6, 29)), isTrue); // just before first trains
    });
  });
}
