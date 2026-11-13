import 'package:core_contracts/core_contracts.dart';

/// Exact purchase-line calculations shared by purchase posting and inventory.
///
/// Quantities follow the existing schema scales: purchase quantity is scale 4,
/// conversion factors and base quantities are scale 6, and money is scale 4.
final class PurchaseLineCalculation {
  const PurchaseLineCalculation({
    required this.totalPacksReceived,
    required this.totalBaseUnitsAdded,
    required this.lineTotal,
    required this.effectivePackCost,
    required this.effectiveBaseCost,
  });

  final ScaledDecimal totalPacksReceived;
  final ScaledDecimal totalBaseUnitsAdded;
  final MoneyAmount lineTotal;
  final MoneyAmount effectivePackCost;
  final ScaledDecimal effectiveBaseCost;
}

/// Pure calculations for supplier invoices, bonus quantities and weighted cost.
///
/// This class deliberately performs no SQL, persistence, sync, or UI work.
abstract final class PurchaseMoneyCalculator {
  static const int quantityScale = 4;
  static const int stockScale = 6;
  static const int moneyScale = MoneyAmount.scale;

  /// Calculates a purchase line. Bonus packs increase stock but are not paid.
  static PurchaseLineCalculation calculateLine({
    required Object? paidQuantity,
    required Object? bonusQuantity,
    required Object? conversionFactor,
    required Object? purchaseUnitPrice,
    Object? lineDiscountAmount = '0',
  }) {
    final paid = ScaledDecimal.parse(paidQuantity, scale: quantityScale);
    final bonus = ScaledDecimal.parse(bonusQuantity, scale: quantityScale);
    final factor = ScaledDecimal.parse(conversionFactor, scale: stockScale);
    final unitPrice = MoneyAmount.parse(purchaseUnitPrice);
    final discount = MoneyAmount.parse(lineDiscountAmount);

    if (paid.isNegative || bonus.isNegative || paid.isZero || factor.isNegative ||
        factor.isZero || unitPrice.isNegative || discount.isNegative) {
      throw const FormatException('Purchase quantities, factor, price and discount are invalid.');
    }

    final totalPacks = paid + bonus;
    final baseUnits = totalPacks.multiply(factor, resultScale: stockScale);
    final gross = MoneyAmount.fromString(paid.toFixedString()).multiply(unitPrice);
    final lineTotal = gross - discount;
    if (lineTotal.isNegative) {
      throw const FormatException('Line discount cannot exceed the paid line value.');
    }
    if (baseUnits.isZero) {
      throw const FormatException('A purchase line must add a positive base quantity.');
    }

    return PurchaseLineCalculation(
      totalPacksReceived: totalPacks,
      totalBaseUnitsAdded: baseUnits,
      lineTotal: lineTotal,
      effectivePackCost: _divideMoneyByQuantity(
        lineTotal,
        paid + bonus,
      ),
      effectiveBaseCost: _divideMoneyByQuantityAsDecimal(
        lineTotal,
        baseUnits,
        stockScale,
      ),
    );
  }

  /// Recalculates weighted average base-unit cost after a purchase.
  ///
  /// Both stock quantities and unit costs use the schema's six-place scale.
  /// The extended values are rounded to NUMERIC(20,4) money before division.
  static ScaledDecimal weightedAverageBaseCost({
    required Object? oldStockBaseQuantity,
    required Object? oldAverageBaseCost,
    required Object? addedBaseQuantity,
    required MoneyAmount purchaseLineTotal,
  }) {
    final oldQty = ScaledDecimal.parse(oldStockBaseQuantity, scale: stockScale);
    final oldCost = ScaledDecimal.parse(oldAverageBaseCost, scale: stockScale);
    final addedQty = ScaledDecimal.parse(addedBaseQuantity, scale: stockScale);
    if (oldQty.isNegative || oldCost.isNegative || addedQty.isNegative ||
        oldQty.isZero && addedQty.isZero) {
      throw const FormatException('Weighted-average inputs are invalid.');
    }

    final oldValue = oldQty.multiply(oldCost, resultScale: moneyScale);
    final totalValue = oldValue +
        ScaledDecimal.fromString(purchaseLineTotal.toFixedString(), scale: moneyScale);
    final totalQty = oldQty + addedQty;
    return _divideMoneyByQuantityAsDecimal(totalValue, totalQty, stockScale);
  }

  static MoneyAmount _divideMoneyByQuantity(
    MoneyAmount amount,
    ScaledDecimal quantity,
  ) {
    final result = _divideMoneyByQuantityAsDecimal(
      ScaledDecimal.fromString(amount.toFixedString(), scale: moneyScale),
      quantity,
      moneyScale,
    );
    return MoneyAmount.fromString(result.toFixedString());
  }

  /// Divides scale-4 money by a quantity at [quantity.scale], returning a
  /// decimal at [resultScale] with half-away-from-zero rounding.
  static ScaledDecimal _divideMoneyByQuantityAsDecimal(
    Object amount,
    ScaledDecimal quantity,
    int resultScale,
  ) {
    final money = amount is MoneyAmount
        ? ScaledDecimal.fromString(amount.toFixedString(), scale: moneyScale)
        : amount as ScaledDecimal;
    if (quantity.isZero || quantity.isNegative) {
      throw const FormatException('Cannot divide by a non-positive quantity.');
    }

    // (money.units / 10^4) / (quantity.units / 10^quantity.scale)
    // expressed in resultScale integer units.
    final numerator = money.units * BigInt.from(10).pow(quantity.scale + resultScale - moneyScale);
    final denominator = quantity.units;
    final negative = numerator.isNegative;
    final absolute = numerator.abs();
    var quotient = absolute ~/ denominator;
    final remainder = absolute.remainder(denominator);
    if (remainder * BigInt.from(2) >= denominator) quotient += BigInt.one;
    final rounded = negative ? -quotient : quotient;
    return ScaledDecimal.fromString(
      _unitsToFixed(rounded, resultScale),
      scale: resultScale,
    );
  }

  static String _unitsToFixed(BigInt units, int scale) {
    final negative = units.isNegative;
    final digits = units.abs().toString().padLeft(scale + 1, '0');
    if (scale == 0) return '${negative ? '-' : ''}${units.abs()}';
    final split = digits.length - scale;
    return '${negative ? '-' : ''}${digits.substring(0, split)}.${digits.substring(split)}';
  }
}

/// Immutable snapshot of one FEFO batch's sellable quantity.
final class FefoBatchBalance {
  const FefoBatchBalance({
    required this.id,
    required this.expiryDate,
    required this.createdAt,
    required this.sealedCartons,
    required this.looseBaseQuantity,
    required this.packConversionFactor,
    this.active = true,
  });

  final String id;
  final DateTime expiryDate;
  final DateTime createdAt;
  final int sealedCartons;
  final ScaledDecimal looseBaseQuantity;
  final ScaledDecimal packConversionFactor;
  final bool active;

  ScaledDecimal get totalBaseQuantity =>
      ScaledDecimal.fromString(sealedCartons.toString(), scale: packConversionFactor.scale)
          .multiply(packConversionFactor, resultScale: packConversionFactor.scale) +
      looseBaseQuantity;
}

/// One deterministic allocation from a batch, including automatic carton opening.
final class FefoBatchAllocation {
  const FefoBatchAllocation({
    required this.batchId,
    required this.cartonsOpened,
    required this.quantityDeducted,
    required this.remainingSealedCartons,
    required this.remainingLooseBaseQuantity,
  });

  final String batchId;
  final int cartonsOpened;
  final ScaledDecimal quantityDeducted;
  final int remainingSealedCartons;
  final ScaledDecimal remainingLooseBaseQuantity;
}

/// Result of planning a sale's batch deductions without mutating persistence.
final class FefoAllocationPlan {
  const FefoAllocationPlan({
    required this.allocations,
    required this.unallocatedQuantity,
  });

  final List<FefoBatchAllocation> allocations;
  final ScaledDecimal unallocatedQuantity;

  bool get isFullyAllocated => unallocatedQuantity.isZero;
}

/// Pure FEFO ordering and carton-unpack planner.
///
/// The caller must invoke this inside the existing sale transaction after
/// locking eligible batch rows. This planner does not lock rows or write SQL.
abstract final class FefoAllocationPlanner {
  static FefoAllocationPlan plan({
    required Iterable<FefoBatchBalance> batches,
    required ScaledDecimal requiredBaseQuantity,
    required DateTime businessDate,
  }) {
    if (requiredBaseQuantity.isNegative || requiredBaseQuantity.isZero) {
      throw const FormatException('Required sale quantity must be positive.');
    }

    final allBatches = batches.toList(growable: false);
    for (final batch in allBatches) {
      if (batch.packConversionFactor.scale != requiredBaseQuantity.scale ||
          batch.looseBaseQuantity.scale != requiredBaseQuantity.scale) {
        throw ArgumentError('FEFO quantities and pack factors must use the same scale.');
      }
      if (batch.sealedCartons < 0 || batch.packConversionFactor.isNegative ||
          batch.packConversionFactor.isZero || batch.looseBaseQuantity.isNegative ||
          batch.looseBaseQuantity.compareTo(batch.packConversionFactor) >= 0) {
        throw const FormatException('FEFO batch balance is invalid.');
      }
    }
    final eligible = allBatches.where((batch) =>
        batch.active &&
        !batch.expiryDate.isBefore(DateTime(businessDate.year, businessDate.month, businessDate.day)) &&
        !batch.totalBaseQuantity.isZero).toList()
      ..sort((a, b) {
        final expiry = a.expiryDate.compareTo(b.expiryDate);
        if (expiry != 0) return expiry;
        final created = a.createdAt.compareTo(b.createdAt);
        return created != 0 ? created : a.id.compareTo(b.id);
      });

    var remaining = requiredBaseQuantity;
    final allocations = <FefoBatchAllocation>[];
    for (final batch in eligible) {
      if (remaining.isZero) break;
      final scale = remaining.scale;
      if (batch.packConversionFactor.scale != scale || batch.looseBaseQuantity.scale != scale) {
        throw ArgumentError('FEFO quantities and pack factors must use the same scale.');
      }
      var loose = batch.looseBaseQuantity;
      var cartons = batch.sealedCartons;
      final factor = batch.packConversionFactor;
      final available = batch.totalBaseQuantity;
      final deduction = available.compareTo(remaining) <= 0 ? available : remaining;
      var opened = 0;
      if (deduction.compareTo(loose) > 0) {
        final shortfall = deduction - loose;
        final quotient = shortfall.units ~/ factor.units;
        final remainder = shortfall.units.remainder(factor.units);
        opened = (quotient + (remainder == BigInt.zero ? BigInt.zero : BigInt.one)).toInt();
        if (opened > cartons) {
          throw StateError('FEFO batch balance is inconsistent.');
        }
        cartons -= opened;
        loose = loose +
            ScaledDecimal.fromString(opened.toString(), scale: scale)
                .multiply(factor, resultScale: scale);
      }
      loose = loose - deduction;
      allocations.add(FefoBatchAllocation(
        batchId: batch.id,
        cartonsOpened: opened,
        quantityDeducted: deduction,
        remainingSealedCartons: cartons,
        remainingLooseBaseQuantity: loose,
      ));
      remaining = remaining - deduction;
    }

    return FefoAllocationPlan(
      allocations: List.unmodifiable(allocations),
      unallocatedQuantity: remaining,
    );
  }
}
