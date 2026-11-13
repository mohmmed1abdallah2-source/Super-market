import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:supermarket_erp/data/database/schema_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('fresh local schema creates Iteration 3 tables and exact decimal columns', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);

    await db.execute('PRAGMA foreign_keys = ON');
    await SchemaBuilder.createAll(db);

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = tables.map((row) => row['name']).toSet();
    for (final table in [
      'warehouses',
      'aisle_shelf_locations',
      'product_batches_fefo',
      'purchase_invoices',
      'purchase_invoice_items',
      'stocktaking_sessions',
      'stocktaking_lines',
      'disposals',
      'stock_transfers',
      'purchase_returns',
      'price_cost_history',
      'sales_invoice_item_batches',
    ]) {
      expect(names, contains(table));
    }

    final products = await db.rawQuery('PRAGMA table_info(products)');
    expect(products.map((row) => row['name']), contains('stock_base_qty_exact'));
    expect(products.map((row) => row['name']), contains('avg_cost_base_unit_exact'));

    final movements = await db.rawQuery('PRAGMA table_info(stock_movements)');
    expect(movements.map((row) => row['name']), contains('product_batch_id'));
    expect(movements.map((row) => row['name']), contains('warehouse_id'));
  });
}
