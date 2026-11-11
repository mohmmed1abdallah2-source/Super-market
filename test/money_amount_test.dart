import 'package:flutter_test/flutter_test.dart';
import 'package:core_contracts/core_contracts.dart';

void main() {
  group('MoneyAmount', () {
    test('parses and serializes exact four-place values', () {
      expect(MoneyAmount.fromString('12.3400').toFixedString(), '12.3400');
      expect(MoneyAmount.fromString('-0.0001').toFixedString(), '-0.0001');
      expect(MoneyAmount.fromString('.5').toString(), throwsFormatException);
    });

    test('adds and subtracts without binary floating point drift', () {
      final result = MoneyAmount.fromString('0.1') +
          MoneyAmount.fromString('0.2');
      expect(result.toFixedString(), '0.3000');
      expect((result - MoneyAmount.fromString('0.2')).toFixedString(),
          '0.1000');
    });

    test('multiplies and rounds half away from zero', () {
      expect(
        MoneyAmount.fromString('1.2345')
            .multiply(MoneyAmount.fromString('2'))
            .toFixedString(),
        '2.4690',
      );
      expect(
        MoneyAmount.fromString('0.0001')
            .multiply(MoneyAmount.fromString('0.5000'))
            .toFixedString(),
        '0.0001',
      );
      expect(
        MoneyAmount.fromString('-0.0001')
            .multiply(MoneyAmount.fromString('0.5000'))
            .toFixedString(),
        '-0.0001',
      );
    });

    test('rejects excess precision and non-finite values', () {
      expect(() => MoneyAmount.fromString('1.00001'), throwsFormatException);
      expect(() => MoneyAmount.parse(double.infinity), throwsFormatException);
    });

    test('compares values exactly', () {
      expect(
        MoneyAmount.fromString('10.0000')
            .compareTo(MoneyAmount.fromString('9.9999')),
        greaterThan(0),
      );
      expect(MoneyAmount.fromString('0.0000').isZero, isTrue);
    });
  });
}
