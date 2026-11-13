import 'package:core_contracts/core_contracts.dart';

/// Exact fixed-scale calculations used by the server's sale-posting path.
///
/// Quantities and conversion factors are represented at scale four, matching
/// the current PostgreSQL numeric columns. Monetary values never pass through
/// binary floating-point arithmetic in these helpers.
final class SaleMoneyCalculator {
  const SaleMoneyCalculator._();

  static MoneyAmount amount(Object? value, {MoneyAmount? fallback}) =>
      MoneyAmount.parse(value, fallback: fallback);

  static MoneyAmount lineTotal({
    required Object? quantity,
    required Object? unitPrice,
  }) =>
      amount(quantity).multiply(amount(unitPrice));

  static MoneyAmount baseQuantity({
    required Object? quantity,
    required Object? conversionFactor,
  }) =>
      amount(quantity).multiply(amount(conversionFactor));

  static MoneyAmount inventoryCost({
    required Object? baseQuantity,
    required Object? averageUnitCost,
  }) =>
      amount(baseQuantity).multiply(amount(averageUnitCost));

  static MoneyAmount sum(Iterable<MoneyAmount> values) =>
      values.fold(MoneyAmount.zero, (total, value) => total + value);

  static void validateInvoice({
    required MoneyAmount subtotal,
    required MoneyAmount discount,
    required MoneyAmount cash,
    required MoneyAmount wallet,
    required MoneyAmount credit,
  }) {
    if (discount.isNegative || discount.compareTo(subtotal) > 0) {
      throw const FormatException('Discount is outside the permitted range.');
    }
    if (cash.isNegative || wallet.isNegative || credit.isNegative) {
      throw const FormatException('Payment totals cannot be negative.');
    }
    final net = subtotal - discount;
    if (cash + wallet + credit != net) {
      throw const FormatException(
        'Payments and outstanding amount do not match invoice total.',
      );
    }
  }
}
