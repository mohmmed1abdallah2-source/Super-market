import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

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
          "INSERT INTO products (id, branch_id, sku_code, name_ar, product_type, base_unit_name, stock_base_qty, avg_cost_base_unit, last_cost_base_unit) VALUES (@id, 'branch-main', @sku, 'صنف اختبار', 'STANDARD', 'حبة', 10, 1, 1)",
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
              'amount': 5,
              'cashAccountId': 'cash-drawer',
            }
          ],
          'discountAmount': 0,
          'changeReturned': 0,
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
        expect(double.parse(stock.single.values.first['stock'] as String), 9);

        final totals = await connection.mappedResultsQuery(
          "SELECT COALESCE(SUM(dr_amount),0)::text AS dr, COALESCE(SUM(cr_amount),0)::text AS cr FROM journal_lines WHERE journal_entry_id=(SELECT journal_entry_id FROM sales_invoices WHERE id=@id)",
          substitutionValues: {'id': first['id']},
        );
        final line = totals.single.values.first;
        expect(double.parse(line['dr'] as String), closeTo(double.parse(line['cr'] as String), 0.0001));
      } finally {
        await connection.close();
      }
    },
    skip: Platform.environment['PGTEST_HOST'] == null,
  );
}
