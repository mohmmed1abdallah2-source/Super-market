import 'package:core_contracts/core_contracts.dart';
import 'package:test/test.dart';
import 'package:supermarket_erp_server/features/inventory_and_purchases/domain/purchase_and_fefo_calculator.dart';

void main() {
  group('PurchaseMoneyCalculator', () {
    test('includes free bonus packs in received quantity but not paid value', () {
      final result = PurchaseMoneyCalculator.calculateLine(
        paidQuantity: '2.0000',
        bonusQuantity: '1.0000',
        conversionFactor: '24.000000',
        purchaseUnitPrice: '10.0000',
      );

      expect(result.totalPacksReceived.toFixedString(), '3.0000');
      expect(result.totalBaseUnitsAdded.toFixedString(), '72.000000');
      expect(result.lineTotal.toFixedString(), '20.0000');
      expect(result.effectivePackCost.toFixedString(), '6.6667');
      expect(result.effectiveBaseCost.toFixedString(), '0.277778');
    });

    test('applies line discount to paid value and rejects excess discount', () {
      final result = PurchaseMoneyCalculator.calculateLine(
        paidQuantity: '2.0000',
        bonusQuantity: '1.0000',
        conversionFactor: '12.000000',
        purchaseUnitPrice: '5.0000',
        lineDiscountAmount: '1.2500',
      );
      expect(result.lineTotal.toFixedString(), '8.7500');
      expect(
        () => PurchaseMoneyCalculator.calculateLine(
          paidQuantity: '1.0000',
          bonusQuantity: '0.0000',
          conversionFactor: '1.000000',
          purchaseUnitPrice: '1.0000',
          lineDiscountAmount: '1.0001',
        ),
        throwsFormatException,
      );
    });

    test('calculates weighted average at six-place stock cost scale', () {
      final result = PurchaseMoneyCalculator.weightedAverageBaseCost(
        oldStockBaseQuantity: '48.000000',
        oldAverageBaseCost: '0.250000',
        addedBaseQuantity: '72.000000',
        purchaseLineTotal: MoneyAmount.fromString('20.0000'),
      );
      expect(result.toFixedString(), '0.266667');
    });
  });

  group('FefoAllocationPlanner', () {
    final today = DateTime(2026, 11, 13);

    FefoBatchBalance batch({
      required String id,
      required int day,
      int cartons = 2,
      String loose = '0.000000',
      String factor = '24.000000',
      bool active = true,
    }) =>
        FefoBatchBalance(
          id: id,
          expiryDate: DateTime(2026, 12, day),
          createdAt: DateTime(2026, 10, day),
          sealedCartons: cartons,
          looseBaseQuantity: ScaledDecimal.fromString(loose, scale: 6),
          packConversionFactor: ScaledDecimal.fromString(factor, scale: 6),
          active: active,
        );

    test('uses earliest expiry and automatically opens one carton', () {
      final plan = FefoAllocationPlanner.plan(
        batches: [batch(id: 'later', day: 15), batch(id: 'earlier', day: 1)],
        requiredBaseQuantity: ScaledDecimal.fromString('3.000000', scale: 6),
        businessDate: today,
      );

      expect(plan.isFullyAllocated, isTrue);
      expect(plan.allocations, hasLength(1));
      expect(plan.allocations.single.batchId, 'earlier');
      expect(plan.allocations.single.cartonsOpened, 1);
      expect(plan.allocations.single.remainingSealedCartons, 1);
      expect(plan.allocations.single.remainingLooseBaseQuantity.toFixedString(), '21.000000');
    });

    test('does not allocate expired or inactive batches', () {
      final expired = FefoBatchBalance(
        id: 'expired',
        expiryDate: DateTime(2026, 11, 12),
        createdAt: DateTime(2026, 10, 1),
        sealedCartons: 10,
        looseBaseQuantity: ScaledDecimal.fromString('0.000000', scale: 6),
        packConversionFactor: ScaledDecimal.fromString('24.000000', scale: 6),
      );
      final plan = FefoAllocationPlanner.plan(
        batches: [expired, batch(id: 'inactive', day: 10, active: false)],
        requiredBaseQuantity: ScaledDecimal.fromString('1.000000', scale: 6),
        businessDate: today,
      );
      expect(plan.allocations, isEmpty);
      expect(plan.unallocatedQuantity.toFixedString(), '1.000000');
    });

    test('returns unallocated quantity instead of allowing negative stock', () {
      final plan = FefoAllocationPlanner.plan(
        batches: [batch(id: 'only-batch', day: 1, cartons: 1)],
        requiredBaseQuantity: ScaledDecimal.fromString('30.000000', scale: 6),
        businessDate: today,
      );
      expect(plan.allocations.single.quantityDeducted.toFixedString(), '24.000000');
      expect(plan.isFullyAllocated, isFalse);
      expect(plan.unallocatedQuantity.toFixedString(), '6.000000');
    });
  });
}
