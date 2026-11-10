import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import '../lib/features/ledger/data/postgres_ledger_repository.dart';
import '../lib/features/ledger/domain/ledger_domain.dart';
import '../lib/features/sales_and_sync/data/postgres_sales_sync_repository.dart';
import '../lib/features/sales_and_sync/domain/sales_sync_domain.dart';

void main() {
  test(
    'PostgreSQL mixed tender sale and customer settlement preserve balances and idempotency',
    () async {
      final environment = Platform.environment;
      final connection = PostgreSQLConnection(
        environment['PGTEST_HOST']!,
        int.tryParse(environment['PGTEST_PORT'] ?? '5432') ?? 5432,
        environment['PGTEST_DATABASE']!,
        username: environment['PGTEST_USER']!,
        password: environment['PGTEST_PASSWORD']!,
        timeoutInSeconds: 30,
      );
      await connection.open();
      try {
        final uuid = const Uuid();
        final ledger = PostgresLedgerRepository(connection);
        final sales = PostgresSalesSyncRepository(connection);
        final partyCode = 'MIX-' + uuid.v4().substring(0, 8);
        final partyRequest = {
          'partyType': 'CUSTOMER',
          'code': partyCode,
          'name': 'عميل اختبار الدفع المختلط',
          'creditLimit': 100,
          'paymentTermsDays': 0,
          'priceTier': 'RETAIL',
        };
        final party = await ledger.createParty(
          CreatePartyCommand(
            branchId: 'branch-main',
            partyType: LedgerPartyType.customer,
            code: partyCode,
            name: 'عميل اختبار الدفع المختلط',
            creditLimit: 100,
            paymentTermsDays: 0,
            priceTier: 'RETAIL',
          ),
          idempotencyKey: 'mixed-party-' + uuid.v4(),
          requestHash: sha256.convert(utf8.encode(jsonEncode(partyRequest))).toString(),
        );
        final productId = 'mixed-product-' + uuid.v4();
        await connection.execute(
          '''INSERT INTO products
             (id, branch_id, sku_code, name_ar, product_type, base_unit_name,
              stock_base_qty, avg_cost_base_unit, last_cost_base_unit)
             VALUES (@id, 'branch-main', @sku, 'صنف دفع مختلط', 'STANDARD',
                     'حبة', 20, 1, 1)''',
          substitutionValues: {'id': productId, 'sku': productId},
        );

        final operationId = uuid.v4();
        final saleRequest = <String, dynamic>{
          'operationId': operationId,
          'customerPartyId': party['id'],
          'priceTier': 'RETAIL',
          'items': [
            {
              'id': uuid.v4(),
              'productId': productId,
              'unitName': 'حبة',
              'qtySold': 1,
              'conversionFactor': 1,
              'unitPrice': 5,
              'lineTotal': 5,
            }
          ],
          'payments': [
            {
              'id': uuid.v4(),
              'method': 'CASH',
              'amount': 2,
              'cashAccountId': 'cash-drawer',
            },
            {
              'id': uuid.v4(),
              'method': 'WALLET',
              'amount': 1,
              'cashAccountId': 'wallet-jaib',
              'walletProvider': 'JEEB',
              'walletRefNo': 'REF-123456',
            },
            {
              'id': uuid.v4(),
              'method': 'CREDIT',
              'amount': 2,
              'cashAccountId': null,
            },
          ],
          'discountAmount': 0,
          'changeReturned': 0,
        };
        final saleCommand = SaleInvoiceCommand(
          branchId: 'branch-main',
          operationId: operationId,
          request: saleRequest,
          idempotencyKey: 'mixed-sale-' + uuid.v4(),
          requestHash: sha256.convert(utf8.encode(jsonEncode(saleRequest))).toString(),
        );

        final firstSale = await sales.postSale(saleCommand);
        final replayedSale = await sales.postSale(saleCommand);
        expect(replayedSale['id'], firstSale['id']);
        expect(double.parse(firstSale['netTotal'] as String), 5);
        expect(double.parse(firstSale['paidTotal'] as String), 3);
        expect(double.parse(firstSale['remainingAlayh'] as String), 2);

        final invoiceRows = await connection.mappedResultsQuery(
          '''SELECT sale_type AS "saleType", paid_total::text AS paid,
                    remaining_alayh::text AS remaining
             FROM sales_invoices WHERE id = @id''',
          substitutionValues: {'id': firstSale['id']},
        );
        final invoice = invoiceRows.single.values.first;
        expect(invoice['saleType'], 'MIXED');
        expect(double.parse(invoice['paid'] as String), 3);
        expect(double.parse(invoice['remaining'] as String), 2);

        final paymentRows = await connection.mappedResultsQuery(
          '''SELECT method, amount::text AS amount FROM sales_payments
             WHERE invoice_id = @invoice ORDER BY method''',
          substitutionValues: {'invoice': firstSale['id']},
        );
        expect(paymentRows.length, 3);
        final methods = paymentRows.map((row) => row.values.first['method']).toSet();
        expect(methods, {'CASH', 'WALLET', 'CREDIT'});

        final ledgerBeforeSettlement = await connection.mappedResultsQuery(
          '''SELECT total_alayh::text AS alayh, total_lah::text AS lah
             FROM v_party_balance WHERE party_id = @party''',
          substitutionValues: {'party': party['id']},
        );
        expect(
          double.parse(ledgerBeforeSettlement.single.values.first['alayh'] as String),
          2,
        );

        final saleJournal = await connection.mappedResultsQuery(
          '''SELECT COALESCE(SUM(dr_amount), 0)::text AS dr,
                    COALESCE(SUM(cr_amount), 0)::text AS cr
             FROM journal_lines
             WHERE journal_entry_id = (SELECT journal_entry_id FROM sales_invoices WHERE id = @id)''',
          substitutionValues: {'id': firstSale['id']},
        );
        final saleTotals = saleJournal.single.values.first;
        expect(
          double.parse(saleTotals['dr'] as String),
          closeTo(double.parse(saleTotals['cr'] as String), 0.0001),
        );

        // Settle the customer's remaining balance with an idempotent receipt voucher.
        final settlementRequest = {
          'voucherType': 'RECEIPT',
          'partyId': party['id'],
          'cashAccountId': 'cash-drawer',
          'amount': 2,
          'method': 'CASH',
          'description': 'تسوية رصيد فاتورة الدفع المختلط',
        };
        final settlementCommand = PostVoucherCommand(
          branchId: 'branch-main',
          operationId: uuid.v4(),
          voucherType: LedgerVoucherType.receipt,
          partyId: party['id'] as String,
          cashAccountId: 'cash-drawer',
          amount: 2,
          method: 'CASH',
          idempotencyKey: 'settlement-' + uuid.v4(),
          requestHash: sha256.convert(utf8.encode(jsonEncode(settlementRequest))).toString(),
          description: 'تسوية رصيد فاتورة الدفع المختلط',
        );
        final firstSettlement = await ledger.postVoucher(settlementCommand);
        final replayedSettlement = await ledger.postVoucher(settlementCommand);
        expect(replayedSettlement['id'], firstSettlement['id']);

        final finalBalance = await connection.mappedResultsQuery(
          '''SELECT total_alayh::text AS alayh, total_lah::text AS lah,
                    balance_abs::text AS balance
             FROM v_party_balance WHERE party_id = @party''',
          substitutionValues: {'party': party['id']},
        );
        final balance = finalBalance.single.values.first;
        expect(double.parse(balance['alayh'] as String), 2);
        expect(double.parse(balance['lah'] as String), 2);
        expect(double.parse(balance['balance'] as String), 0);

        final voucherCount = await connection.mappedResultsQuery(
          '''SELECT COUNT(*)::text AS count FROM vouchers
             WHERE branch_id = 'branch-main' AND operation_id = @operation''',
          substitutionValues: {'operation': settlementCommand.operationId},
        );
        expect(int.parse(voucherCount.single.values.first['count'] as String), 1);
      } finally {
        await connection.close();
      }
    },
    skip: Platform.environment['PGTEST_HOST'] == null,
  );
}
