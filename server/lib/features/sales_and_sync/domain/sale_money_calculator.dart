import 'package:core_contracts/core_contracts.dart';

/// Exact field-scale calculations for the server's sale-posting domain.
///
/// Monetary values use scale four. Sale quantities use scale four, while
/// conversion factors and base inventory quantities use scale six, matching
/// migrations 001 and 002. This helper is not yet wired into the repository's
/// live SQL transaction.
final class SaleMoneyCalculator {
  const SaleMoneyCalculator._();

  static MoneyAmount amount(Object? value, {MoneyAmount? fallback}) =>
      MoneyAmount.parse(value, fallback: fallback);

  static MoneyAmount lineTotal({
    required Object? quantity,
    required Object? unitPrice,
  }) {
    final qty = ScaledDecimal.parse(quantity, scale: 4);
    final price = ScaledDecimal.parse(unitPrice, scale: 4);
    final total = qty.multiply(price, resultScale: 4);
    return MoneyAmount.parse(total.toFixedString());
  }

  static ScaledDecimal baseQuantity({
    required Object? quantity,
    required Object? conversionFactor,
  }) {
    final qty = ScaledDecimal.parse(quantity, scale: 4);
    final factor = ScaledDecimal.parse(conversionFactor, scale: 6);
    return qty.multiply(factor, resultScale: 6);
  }

  static MoneyAmount inventoryCost({
    required Object? baseQuantity,
    required Object? averageUnitCost,
  }) {
    final quantity = baseQuantity is ScaledDecimal
        ? baseQuantity
        : ScaledDecimal.parse(baseQuantity, scale: 6);
    final unitCost = ScaledDecimal.parse(averageUnitCost, scale: 6);
    final cost = quantity.multiply(unitCost, resultScale: 4);
    return MoneyAmount.parse(cost.toFixedString());
  }

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
