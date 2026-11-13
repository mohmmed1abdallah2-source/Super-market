import 'package:core_contracts/core_contracts.dart';
import 'package:test/test.dart';

void main() {
  test('purchase invoice item JSON preserves four- and six-place decimals', () {
    final item = PurchaseInvoiceItemDto(
      id: 'line-1',
      productId: 'product-1',
      qtyPaid: ScaledDecimal.fromString('2.0000', scale: 4),
      bonusQty: ScaledDecimal.fromString('1.0000', scale: 4),
      conversionFactor: ScaledDecimal.fromString('24.000000', scale: 6),
      purchaseUnitPrice: MoneyAmount.fromString('10.0000'),
      lineDiscountAmount: MoneyAmount.fromString('0.0000'),
      lineTotal: MoneyAmount.fromString('20.0000'),
      totalBaseUnitsAdded: ScaledDecimal.fromString('72.000000', scale: 6),
      effectivePackCost: MoneyAmount.fromString('6.6667'),
      effectiveBaseCost: ScaledDecimal.fromString('0.277778', scale: 6),
    );

    final restored = PurchaseInvoiceItemDto.fromJson(item.toJson());
    expect(restored.qtyPaid.toFixedString(), '2.0000');
    expect(restored.bonusQty.toFixedString(), '1.0000');
    expect(restored.conversionFactor.toFixedString(), '24.000000');
    expect(restored.purchaseUnitPrice.toFixedString(), '10.0000');
    expect(restored.effectiveBaseCost.toFixedString(), '0.277778');
  });

  test('inventory decimal contracts reject floating point JSON values', () {
    expect(
      () => InventoryContractJson.decimal(
        {'qty': 0.1},
        'qty',
        scale: 6,
      ),
      throwsFormatException,
    );
  });
}
