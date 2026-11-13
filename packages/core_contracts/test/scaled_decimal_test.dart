import 'package:core_contracts/scaled_decimal.dart';
import 'package:test/test.dart';

void main() {
  group('ScaledDecimal', () {
    test('preserves six-place stock and conversion values', () {
      final qty = ScaledDecimal.fromString('0.123456', scale: 6);
      final factor = ScaledDecimal.fromString('2.500000', scale: 6);
      expect(qty.multiply(factor, resultScale: 6).toFixedString(), '0.308640');
    });

    test('multiplies four-place invoice quantity and price at money scale', () {
      final qty = ScaledDecimal.fromString('1.2500', scale: 4);
      final price = ScaledDecimal.fromString('0.1000', scale: 4);
      expect(qty.multiply(price, resultScale: 4).toFixedString(), '0.1250');
    });

    test('uses explicit half-away-from-zero rounding', () {
      final positive = ScaledDecimal.fromString('0.000100', scale: 6);
      final half = ScaledDecimal.fromString('0.500000', scale: 6);
      final negative = ScaledDecimal.fromString('-0.000100', scale: 6);
      expect(positive.multiply(half, resultScale: 4).toFixedString(), '0.0001');
      expect(negative.multiply(half, resultScale: 4).toFixedString(), '-0.0001');
    });

    test('rejects precision loss and mixed-scale addition', () {
      expect(() => ScaledDecimal.fromString('1.0000001', scale: 6),
          throwsFormatException);
      expect(
        () => ScaledDecimal.fromString('1.0', scale: 1) +
            ScaledDecimal.fromString('1.00', scale: 2),
        throwsArgumentError,
      );
    });

    test('parses supported JSON numeric values and rejects non-finite doubles', () {
      expect(ScaledDecimal.parse(12, scale: 4).toFixedString(), '12.0000');
      expect(ScaledDecimal.parse(1.25, scale: 4).toFixedString(), '1.2500');
      expect(() => ScaledDecimal.parse(double.infinity, scale: 4),
          throwsFormatException);
    });
  });
}
