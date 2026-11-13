import 'package:core_contracts/core_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('server shared MoneyAmount contract', () {
    test('parses decimal strings exactly for PostgreSQL NUMERIC(20,4)', () {
      expect(MoneyAmount.parse('0.1') + MoneyAmount.parse('0.2'),
          MoneyAmount.fromString('0.3000'));
      expect(MoneyAmount.parse('125.4').toFixedString(), '125.4000');
      expect(MoneyAmount.parse('-0.0001').toFixedString(), '-0.0001');
    });

    test('multiplies with explicit half-away-from-zero rounding', () {
      expect(
        MoneyAmount.parse('0.0001')
            .multiply(MoneyAmount.parse('0.5000'))
            .toFixedString(),
        '0.0001',
      );
      expect(
        MoneyAmount.parse('-0.0001')
            .multiply(MoneyAmount.parse('0.5000'))
            .toFixedString(),
        '-0.0001',
      );
    });

    test('rejects values that cannot be represented at scale four', () {
      expect(() => MoneyAmount.parse('1.00001'), throwsFormatException);
      expect(() => MoneyAmount.parse(double.nan), throwsFormatException);
    });
  });
}
