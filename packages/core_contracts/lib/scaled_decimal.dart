/// Exact base-10 decimal represented by integer units at a declared scale.
///
/// Unlike [MoneyAmount], this type supports field-specific scales such as
/// four-place invoice quantities and six-place stock/conversion quantities.
/// Parsing rejects excess fractional digits; multiplication requires an
/// explicit result scale so rounding never happens implicitly.
final class ScaledDecimal implements Comparable<ScaledDecimal> {
  const ScaledDecimal._(this.units, this.scale);

  final BigInt units;
  final int scale;

  static BigInt _factor(int scale) {
    if (scale < 0 || scale > 18) {
      throw RangeError.range(scale, 0, 18, 'scale');
    }
    return BigInt.from(10).pow(scale);
  }

  factory ScaledDecimal.fromString(String value, {required int scale}) {
    final factor = _factor(scale);
    final input = value.trim();
    final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(input);
    if (match == null) {
      throw FormatException('Invalid decimal value: $value');
    }
    final fraction = match.group(3) ?? '';
    if (fraction.length > scale) {
      throw FormatException('Decimal value supports at most $scale places.');
    }
    final whole = BigInt.parse(match.group(2)!);
    final fractional = BigInt.parse(fraction.padRight(scale, '0').isEmpty
        ? '0'
        : fraction.padRight(scale, '0'));
    final magnitude = whole * factor + fractional;
    return ScaledDecimal._(
      match.group(1) == '-' ? -magnitude : magnitude,
      scale,
    );
  }

  factory ScaledDecimal.parse(Object? value, {required int scale}) {
    if (value is int) {
      return ScaledDecimal.fromString(value.toString(), scale: scale);
    }
    if (value is double && !value.isFinite) {
      throw FormatException('Decimal value must be finite.');
    }
    if (value is num || value is String) {
      return ScaledDecimal.fromString(value.toString(), scale: scale);
    }
    throw FormatException('Invalid decimal value: $value');
  }

  ScaledDecimal operator +(ScaledDecimal other) {
    _requireSameScale(other);
    return ScaledDecimal._(units + other.units, scale);
  }

  ScaledDecimal operator -(ScaledDecimal other) {
    _requireSameScale(other);
    return ScaledDecimal._(units - other.units, scale);
  }

  ScaledDecimal multiply(
    ScaledDecimal other, {
    required int resultScale,
  }) {
    final product = units * other.units;
    final sourceScale = scale + other.scale;
    if (sourceScale <= resultScale) {
      return ScaledDecimal._(
        product * _factor(resultScale - sourceScale),
        resultScale,
      );
    }

    final divisor = _factor(sourceScale - resultScale);
    final negative = product.isNegative;
    final absolute = product.abs();
    var quotient = absolute ~/ divisor;
    final remainder = absolute.remainder(divisor);
    if (remainder * BigInt.from(2) >= divisor) {
      quotient += BigInt.one;
    }
    return ScaledDecimal._(negative ? -quotient : quotient, resultScale);
  }

  bool get isNegative => units.isNegative;
  bool get isZero => units == BigInt.zero;

  @override
  int compareTo(ScaledDecimal other) {
    _requireSameScale(other);
    return units.compareTo(other.units);
  }

  void _requireSameScale(ScaledDecimal other) {
    if (scale != other.scale) {
      throw ArgumentError('Cannot combine decimals with different scales.');
    }
  }

  String toFixedString() {
    final negative = units.isNegative;
    final digits = units.abs().toString().padLeft(scale + 1, '0');
    if (scale == 0) return '${negative ? '-' : ''}${units.abs()}';
    final split = digits.length - scale;
    final whole = digits.substring(0, split);
    final fraction = digits.substring(split);
    return '${negative ? '-' : ''}$whole.$fraction';
  }

  @override
  String toString() => toFixedString();

  @override
  bool operator ==(Object other) =>
      other is ScaledDecimal && other.scale == scale && other.units == units;

  @override
  int get hashCode => Object.hash(units, scale);
}
