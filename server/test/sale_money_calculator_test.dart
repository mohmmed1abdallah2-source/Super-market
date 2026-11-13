import 'package:supermarket_erp_server/features/sales_and_sync/domain/sale_money_calculator.dart';
import 'package:core_contracts/core_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('SaleMoneyCalculator', () {
    test('calculates line totals and base quantities exactly', () {
      expect(
        SaleMoneyCalculator.lineTotal(quantity: '3', unitPrice: '0.1')
            .toFixedString(),
        '0.3000',
      );
      expect(
        SaleMoneyCalculator.baseQuantity(
          quantity: '1.2500',
          conversionFactor: '12',
        ).toFixedString(),
        '15.0000',
      );
    });

    test('calculates inventory cost without binary floating point drift', () {
      final baseQty = SaleMoneyCalculator.baseQuantity(
        quantity: '0.3',
        conversionFactor: '1',
      );
      expect(
        SaleMoneyCalculator.inventoryCost(
          baseQuantity: baseQty,
          averageUnitCost: '0.1',
        ).toFixedString(),
        '0.0300',
      );
    });

    test('sums exact payment amounts and validates invoice balance', () {
      final cash = MoneyAmount.parse('0.1');
      final wallet = MoneyAmount.parse('0.2');
      final credit = MoneyAmount.parse('0.0');
      expect(SaleMoneyCalculator.sum([cash, wallet]).toFixedString(), '0.3000');
      expect(
        () => SaleMoneyCalculator.validateInvoice(
          subtotal: MoneyAmount.parse('0.35'),
          discount: MoneyAmount.parse('0.05'),
          cash: cash,
          wallet: wallet,
          credit: credit,
        ),
        returnsNormally,
      );
    });

    test('rejects mismatched payments and invalid discount', () {
      expect(
        () => SaleMoneyCalculator.validateInvoice(
          subtotal: MoneyAmount.parse('10'),
          discount: MoneyAmount.parse('0'),
          cash: MoneyAmount.parse('9.9999'),
          wallet: MoneyAmount.zero,
          credit: MoneyAmount.zero,
        ),
        throwsFormatException,
      );
      expect(
        () => SaleMoneyCalculator.validateInvoice(
          subtotal: MoneyAmount.parse('10'),
          discount: MoneyAmount.parse('11'),
          cash: MoneyAmount.zero,
          wallet: MoneyAmount.zero,
          credit: MoneyAmount.zero,
        ),
        throwsFormatException,
      );
    });

    test('rejects quantity or money precision beyond four places', () {
      expect(
        () => SaleMoneyCalculator.lineTotal(
          quantity: '1.00001',
          unitPrice: '2',
        ),
        throwsFormatException,
      );
    });
  });
}
