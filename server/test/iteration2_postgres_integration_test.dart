import 'dart:convert';
import 'dart:io';

import 'package:core_contracts/core_contracts.dart';

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
    'PostgreSQL sale retry is idempotent and journal totals balance',
    () async {
      final host = Platform.environment['PGTEST_HOST']!;
      final connection = PostgreSQLConnection(
        host,
        int.tryParse(Platform.environment['PGTEST_PORT'] ?? '5432') ?? 5432,
        Platform.environment['PGTEST_DATABASE']!,
        username: Platform.environment['PGTEST_USER']!,
        password: Platform.environment['PGTEST_PASSWORD']!,
        timeoutInSeconds: 30,
      );
      await connection.open();
      try {
        final uuid = const Uuid();
        final productId = 'integration-product-' + uuid.v4();
        final operationId = uuid.v4();
        final key = 'integration-sale-' + uuid.v4();
        await connection.execute(
          "INSERT INTO products (id, branch_id, sku_code, name_ar, product_type, base_unit_name, stock_base_qty, avg_cost_base_unit, last_cost_base_unit) VALUES (@id, 'branch-main', @sku, 'صنف اختبار', 'STANDARD', 'حبة', 10, 0.1, 0.1)",
          substitutionValues: {'id': productId, 'sku': productId},
        );
        final request = <String, dynamic>{
          'operationId': operationId,
          'priceTier': 'RETAIL',
          'items': [
            {
              'id': uuid.v4(),
              'productId': productId,
              'unitName': 'حبة',
              'qtySold': '0.3000',
              'conversionFactor': '1.000000',
              'unitPrice': '0.1000',
              'lineTotal': '0.0300',
            }
          ],
          'payments': [
            {
              'id': uuid.v4(),
              'method': 'CASH',
              'amount': '0.0300',
              'cashAccountId': 'cash-drawer',
            }
          ],
          'discountAmount': '0.0000',
          'changeReturned': '0.0000',
        };
        final command = SaleInvoiceCommand(
          branchId: 'branch-main',
          operationId: operationId,
          request: request,
          idempotencyKey: key,
          requestHash: sha256.convert(utf8.encode(jsonEncode(request))).toString(),
        );
        final repository = PostgresSalesSyncRepository(connection);
        final first = await repository.postSale(command);
        final retry = await repository.postSale(command);
        expect(retry['id'], first['id']);

        final stock = await connection.mappedResultsQuery(
          'SELECT stock_base_qty::text AS stock FROM products WHERE id=@id',
          substitutionValues: {'id': productId},
        );
        expect(stock.single.values.first['stock'], '9.700000');

        final totals = await connection.mappedResultsQuery(
          "SELECT COALESCE(SUM(dr_amount),0)::text AS dr, COALESCE(SUM(cr_amount),0)::text AS cr FROM journal_lines WHERE journal_entry_id=(SELECT journal_entry_id FROM sales_invoices WHERE id=@id)",
          substitutionValues: {'id': first['id']},
        );
        final line = totals.single.values.first;
        expect(line['dr'], '0.0600');
        expect(line['cr'], '0.0600');

        final invoiceRows = await connection.mappedResultsQuery(
          '''SELECT net_total::text AS net, paid_total::text AS paid
             FROM sales_invoices WHERE id=@id''',
          substitutionValues: {'id': first['id']},
        );
        expect(invoiceRows.single.values.first['net'], '0.0300');
        expect(invoiceRows.single.values.first['paid'], '0.0300');

        final itemRows = await connection.mappedResultsQuery(
          '''SELECT line_total::text AS total FROM sales_invoice_items
             WHERE invoice_id=@id''',
          substitutionValues: {'id': first['id']},
        );
        expect(itemRows.single.values.first['total'], '0.0300');

        final invalidTenderRequest = Map<String, dynamic>.from(request)
          ..['operationId'] = uuid.v4()
          ..['payments'] = [
            {
              'id': uuid.v4(),
              'method': 'CASH',
              'amount': '0.0100',
              'cashAccountId': 'wallet-jaib',
            },
          ]
          ..['items'] = [
            {
              'id': uuid.v4(),
              'productId': productId,
              'unitName': 'حبة',
              'qtySold': '0.1000',
              'conversionFactor': '1.000000',
              'unitPrice': '0.1000',
              'lineTotal': '0.0100',
            },
          ];
        await expectLater(
          repository.postSale(SaleInvoiceCommand(
            branchId: 'branch-main',
            operationId: invalidTenderRequest['operationId'] as String,
            request: invalidTenderRequest,
            idempotencyKey: 'integration-invalid-tender-' + uuid.v4(),
            requestHash: sha256
                .convert(utf8.encode(jsonEncode(invalidTenderRequest)))
                .toString(),
          )),
          throwsA(isA<StateError>()),
        );
        final stockAfterRejectedTender = await connection.mappedResultsQuery(
          'SELECT stock_base_qty::text AS stock FROM products WHERE id=@id',
          substitutionValues: {'id': productId},
        );
        expect(stockAfterRejectedTender.single.values.first['stock'], '9.700000');
      } finally {
        await connection.close();
      }
    },
    skip: Platform.environment['PGTEST_HOST'] == null,
  );

  test(
    'sync operation ID cannot be reused with a different payload',
    () async {
      final connection = PostgreSQLConnection(
        Platform.environment['PGTEST_HOST']!,
        int.tryParse(Platform.environment['PGTEST_PORT'] ?? '5432') ?? 5432,
        Platform.environment['PGTEST_DATABASE']!,
        username: Platform.environment['PGTEST_USER']!,
        password: Platform.environment['PGTEST_PASSWORD']!,
        timeoutInSeconds: 30,
      );
      await connection.open();
      try {
        final uuid = const Uuid();
        final repository = PostgresSalesSyncRepository(connection);
        final operationId = uuid.v4();
        final partyId = uuid.v4();
        final payload = <String, dynamic>{
          'id': partyId,
          'partyType': 'CUSTOMER',
          'code': 'BATCH-${uuid.v4().substring(0, 8)}',
          'name': 'Original batch customer',
          'creditLimit': '0.0000',
          'paymentTermsDays': 0,
          'priceTier': 'RETAIL',
        };

        SyncBatchCommand commandFor(Map<String, dynamic> operationPayload) {
          final body = {
            'batchId': uuid.v4(),
            'operations': [
              {
                'operationId': operationId,
                'operationType': 'PARTY_CREATE',
                'payload': operationPayload,
              },
            ],
          };
          return SyncBatchCommand(
            branchId: 'branch-main',
            batchId: body['batchId']! as String,
            idempotencyKey: 'integration-batch-' + uuid.v4(),
            requestHash:
                sha256.convert(utf8.encode(jsonEncode(body))).toString(),
            operations: [
              SyncOperation(
                operationId: operationId,
                operationType: 'PARTY_CREATE',
                payload: operationPayload,
              ),
            ],
          );
        }

        final concurrentResults = await Future.wait([
          repository.processBatch(commandFor(payload)),
          repository.processBatch(commandFor(payload)),
        ]);
        for (final result in concurrentResults) {
          expect(result['acceptedIds'], [operationId]);
        }

        final samePayloadRetry =
            await repository.processBatch(commandFor(payload));
        expect(samePayloadRetry['acceptedIds'], [operationId]);

        final conflictingPayload = Map<String, dynamic>.from(payload)
          ..['name'] = 'Conflicting batch customer';
        await expectLater(
          repository.processBatch(commandFor(conflictingPayload)),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'OPERATION_ID_REUSED',
            ),
          ),
        );

        final rows = await connection.mappedResultsQuery(
          'SELECT name_ar AS name FROM parties WHERE id = @id AND branch_id = @branch',
          substitutionValues: {'id': partyId, 'branch': 'branch-main'},
        );
        expect(rows.single.values.first['name'], 'Original batch customer');
      } finally {
        await connection.close();
      }
    },
    skip: Platform.environment['PGTEST_HOST'] == null,
  );

  test(
    'PostgreSQL voucher retry records one ledger movement and balanced journal',
    () async {
      final host = Platform.environment['PGTEST_HOST']!;
      final connection = PostgreSQLConnection(
        host,
        int.tryParse(Platform.environment['PGTEST_PORT'] ?? '5432') ?? 5432,
        Platform.environment['PGTEST_DATABASE']!,
        username: Platform.environment['PGTEST_USER']!,
        password: Platform.environment['PGTEST_PASSWORD']!,
        timeoutInSeconds: 30,
      );
      await connection.open();
      try {
        final uuid = const Uuid();
        final code = 'IT-' + uuid.v4().substring(0, 8);
        final ledger = PostgresLedgerRepository(connection);
        final partyBody = {'partyType': 'CUSTOMER', 'code': code, 'name': 'عميل تكامل'};
        final party = await ledger.createParty(
          CreatePartyCommand(
            branchId: 'branch-main',
            partyType: LedgerPartyType.customer,
            code: code,
            name: 'عميل تكامل',
            creditLimit: MoneyAmount.parse('1000.0000'),
            paymentTermsDays: 0,
            priceTier: 'RETAIL',
          ),
          idempotencyKey: 'integration-party-' + uuid.v4(),
          requestHash: sha256.convert(utf8.encode(jsonEncode(partyBody))).toString(),
        );
        final request = {
          'voucherType': 'RECEIPT',
          'partyId': party['id'],
          'cashAccountId': 'cash-drawer',
          'amount': '5.0000',
          'method': 'CASH',
        };
        final command = PostVoucherCommand(
          branchId: 'branch-main',
          operationId: uuid.v4(),
          voucherType: LedgerVoucherType.receipt,
          partyId: party['id'] as String,
          cashAccountId: 'cash-drawer',
          amount: MoneyAmount.parse('5.0000'),
          method: 'CASH',
          idempotencyKey: 'integration-voucher-' + uuid.v4(),
          requestHash: sha256.convert(utf8.encode(jsonEncode(request))).toString(),
        );
        final first = await ledger.postVoucher(command);
        final retry = await ledger.postVoucher(command);
        expect(retry['id'], first['id']);

        await expectLater(
          PostgresSalesSyncRepository(connection).processBatch(SyncBatchCommand(
            branchId: 'branch-main',
            batchId: 'batch-' + uuid.v4(),
            idempotencyKey: 'integration-batch-voucher-kind-' + uuid.v4(),
            requestHash: List.filled(64, 'c').join(),
            operations: [
              SyncOperation(
                operationId: uuid.v4(),
                operationType: 'VOUCHER',
                payload: {
                  'voucherType': 'RECEIPT',
                  'partyId': party['id'],
                  'cashAccountId': 'cash-drawer',
                  'amount': '1.0000',
                  'method': 'WALLET',
                  'walletRefNo': 'REF-123456',
                },
              ),
            ],
          )),
          throwsA(isA<StateError>()),
        );

        await expectLater(
          ledger.postVoucher(PostVoucherCommand(
            branchId: 'branch-main',
            operationId: uuid.v4(),
            voucherType: LedgerVoucherType.receipt,
            partyId: party['id'] as String,
            cashAccountId: 'cash-drawer',
            amount: MoneyAmount.parse('1.0000'),
            method: 'WALLET',
            idempotencyKey: 'integration-voucher-kind-' + uuid.v4(),
            requestHash: List.filled(64, 'b').join(),
            walletRefNo: 'REF-123456',
          )),
          throwsA(isA<StateError>()),
        );

        final balance = await connection.mappedResultsQuery(
          'SELECT total_lah::text AS lah, total_alayh::text AS alayh FROM v_party_balance WHERE party_id=@party',
          substitutionValues: {'party': party['id']},
        );
        final totals = balance.single.values.first;
        expect(double.parse(totals['lah'] as String), 5);
        expect(double.parse(totals['alayh'] as String), 0);
      } finally {
        await connection.close();
      }
    },
    skip: Platform.environment['PGTEST_HOST'] == null,
  );
}
