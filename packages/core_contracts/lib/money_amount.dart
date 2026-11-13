/// Fixed-scale decimal amount for financial calculations.
///
/// Values are stored as integer ten-thousandths (scale 4), matching the
/// current PostgreSQL NUMERIC(20,4) accounting columns. Parsing rejects
/// precision beyond four fractional digits instead of silently rounding.
/// Multiplication rounds half away from zero to the same scale.
final class MoneyAmount implements Comparable<MoneyAmount> {
  const MoneyAmount._(this.units);

  static const int scale = 4;
  static const int factor = 10000;
  static final BigInt _factor = BigInt.from(factor);

  /// The exact amount in ten-thousandths of the currency unit.
  final BigInt units;

  static const MoneyAmount zero = MoneyAmount._(BigInt.zero);

  factory MoneyAmount.fromString(String value) {
    final input = value.trim();
    final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(input);
    if (match == null) {
      throw FormatException('Invalid money amount: $value');
    }
    final fraction = match.group(3) ?? '';
    if (fraction.length > scale) {
      throw FormatException('Money amount supports at most $scale decimal places.');
    }
    final whole = BigInt.parse(match.group(2)!);
    final fractional = BigInt.parse(fraction.padRight(scale, '0'));
    final magnitude = whole * _factor + fractional;
    return MoneyAmount._(match.group(1) == '-' ? -magnitude : magnitude);
  }

  /// Parses a JSON-compatible integer, finite number, or decimal string.
  factory MoneyAmount.parse(Object? value, {MoneyAmount? fallback}) {
    if (value == null && fallback != null) return fallback;
    if (value is int) return MoneyAmount.fromString(value.toString());
    if (value is double && !value.isFinite) {
      throw FormatException('Money amount must be finite.');
    }
    if (value is num || value is String) {
      return MoneyAmount.fromString(value.toString());
    }
    throw FormatException('Invalid money amount: $value');
  }

  MoneyAmount operator +(MoneyAmount other) =>
      MoneyAmount._(units + other.units);

  MoneyAmount operator -(MoneyAmount other) =>
      MoneyAmount._(units - other.units);

  MoneyAmount operator -() => MoneyAmount._(-units);

  /// Multiplies two fixed-scale values and rounds to four decimal places.
  MoneyAmount multiply(MoneyAmount other) {
    final product = units * other.units;
    final negative = product.isNegative;
    final absolute = product.abs();
    var quotient = absolute ~/ _factor;
    final remainder = absolute.remainder(_factor);
    if (remainder * BigInt.from(2) >= _factor) quotient += BigInt.one;
    return MoneyAmount._(negative ? -quotient : quotient);
  }

  bool get isNegative => units.isNegative;
  bool get isZero => units == BigInt.zero;

  @override
  int compareTo(MoneyAmount other) => units.compareTo(other.units);

  String toFixedString() {
    final negative = units.isNegative;
    final digits = units.abs().toString().padLeft(scale + 1, '0');
    final whole = digits.substring(0, digits.length - scale);
    final fraction = digits.substring(digits.length - scale);
    return '${negative ? '-' : ''}$whole.$fraction';
  }

  @override
  String toString() => toFixedString();

  @override
  bool operator ==(Object other) =>
      other is MoneyAmount && units == other.units;

  @override
  int get hashCode => units.hashCode;
}
).firstMatch(input);
    if (match == null) {
      throw FormatException('Invalid money amount: $value');
    }
    final fraction = match.group(3) ?? '';
    if (fraction.length > scale) {
      throw FormatException('Money amount supports at most $scale decimal places.');
    }
    final whole = BigInt.parse(match.group(2)!);
    final fractional = BigInt.parse(fraction.padRight(scale, '0'));
    final magnitude = whole * _factor + fractional;
    return MoneyAmount._(match.group(1) == '-' ? -magnitude : magnitude);
  }

  /// Parses a JSON-compatible integer, finite number, or decimal string.
  factory MoneyAmount.parse(Object? value, {MoneyAmount? fallback}) {
    if (value == null && fallback != null) return fallback;
    if (value is int) return MoneyAmount.fromString(value.toString());
    if (value is double && !value.isFinite) {
      throw FormatException('Money amount must be finite.');
    }
    if (value is num || value is String) {
      return MoneyAmount.fromString(value.toString());
    }
    throw FormatException('Invalid money amount: $value');
  }

  MoneyAmount operator +(MoneyAmount other) =>
      MoneyAmount._(units + other.units);

  MoneyAmount operator -(MoneyAmount other) =>
      MoneyAmount._(units - other.units);

  MoneyAmount operator -() => MoneyAmount._(-units);

  /// Multiplies two fixed-scale values and rounds to four decimal places.
  MoneyAmount multiply(MoneyAmount other) {
    final product = units * other.units;
    final negative = product.isNegative;
    final absolute = product.abs();
    var quotient = absolute ~/ _factor;
    final remainder = absolute.remainder(_factor);
    if (remainder * BigInt.from(2) >= _factor) quotient += BigInt.one;
    return MoneyAmount._(negative ? -quotient : quotient);
  }

  bool get isNegative => units.isNegative;
  bool get isZero => units == BigInt.zero;

  @override
  int compareTo(MoneyAmount other) => units.compareTo(other.units);

  String toFixedString() {
    final negative = units.isNegative;
    final digits = units.abs().toString().padLeft(scale + 1, '0');
    final whole = digits.substring(0, digits.length - scale);
    final fraction = digits.substring(digits.length - scale);
    return '${negative ? '-' : ''}$whole.$fraction';
  }

  @override
  String toString() => toFixedString();

  @override
  bool operator ==(Object other) =>
      other is MoneyAmount && units == other.units;

  @override
  int get hashCode => units.hashCode;
}
