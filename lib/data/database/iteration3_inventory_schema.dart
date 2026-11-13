import 'package:sqflite/sqflite.dart';

/// Additive local schema for Iteration 3 inventory and purchasing.
///
/// Existing SQLite REAL columns are retained for the legacy POS. New
/// inventory quantities and costs are stored as decimal TEXT so the new
/// workflow does not introduce additional binary floating-point loss.
abstract final class Iteration3InventorySchema {
  static Future<void> createAll(DatabaseExecutor database) async {
    await _addLegacyColumns(database);
    await _createCompositeParentIndexes(database);
    for (final sql in _tables) {
      await database.execute(sql);
    }
    for (final sql in _indexes) {
      await database.execute(sql);
    }
  }

  /// Upgrades a version-one database without dropping or rewriting business rows.
  static Future<void> upgrade(DatabaseExecutor database) async {
    await _addLegacyColumns(database);
    await _createCompositeParentIndexes(database);
    for (final sql in _tables) {
      await database.execute(sql);
    }
    for (final sql in _indexes) {
      await database.execute(sql);
    }
  }

  static Future<void> _addLegacyColumns(DatabaseExecutor database) async {
    await _addColumn(database, 'products', 'stock_base_qty_exact',
        "TEXT NOT NULL DEFAULT '0.000000'");
    await _addColumn(database, 'products', 'avg_cost_base_unit_exact',
        "TEXT NOT NULL DEFAULT '0.000000'");
    await _addColumn(database, 'products', 'last_cost_base_unit_exact',
        "TEXT NOT NULL DEFAULT '0.000000'");
    await _addColumn(database, 'stock_movements', 'warehouse_id', 'TEXT');
    await _addColumn(database, 'stock_movements', 'product_batch_id', 'TEXT');
    await _addColumn(database, 'stock_movements', 'reference_no', 'TEXT');
    await _addColumn(database, 'stock_movements', 'notes', "TEXT NOT NULL DEFAULT ''");

    // Seed exact text snapshots once from the existing SQLite values. This is
    // a compatibility bridge only; it does not claim to recover lost precision.
    await database.execute('''
      UPDATE products
      SET stock_base_qty_exact = CAST(stock_base_qty AS TEXT)
      WHERE stock_base_qty_exact = '0.000000' AND stock_base_qty <> 0
    ''');
    await database.execute('''
      UPDATE products
      SET avg_cost_base_unit_exact = CAST(avg_cost_base_unit AS TEXT)
      WHERE avg_cost_base_unit_exact = '0.000000' AND avg_cost_base_unit <> 0
    ''');
    await database.execute('''
      UPDATE products
      SET last_cost_base_unit_exact = CAST(last_cost_base_unit AS TEXT)
      WHERE last_cost_base_unit_exact = '0.000000' AND last_cost_base_unit <> 0
    ''');
  }

  static Future<void> _addColumn(
    DatabaseExecutor database,
    String table,
    String column,
    String declaration,
  ) async {
    final rows = await database.rawQuery('PRAGMA table_info($table)');
    if (rows.any((row) => row['name'] == column)) return;
    await database.execute('ALTER TABLE $table ADD COLUMN $column $declaration');
  }

  static Future<void> _createCompositeParentIndexes(
    DatabaseExecutor database,
  ) async {
    const indexes = [
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_products_id_branch ON products(id, branch_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_units_id_branch ON product_units_barcodes(id, branch_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_parties_id_branch ON parties(id, branch_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_users_id_branch ON users(id, branch_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_journal_entries_id_branch ON journal_entries(id, branch_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_cash_accounts_id_branch ON cash_accounts(id, branch_id)',
      'CREATE UNIQUE INDEX IF NOT EXISTS ux_sales_items_id_branch ON sales_invoice_items(id, branch_id)',
    ];
    for (final sql in indexes) {
      await database.execute(sql);
    }
  }

  static const List<String> _tables = [
    '''CREATE TABLE IF NOT EXISTS warehouses (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      code TEXT NOT NULL, name_ar TEXT NOT NULL,
      warehouse_type TEXT NOT NULL DEFAULT 'BACKROOM'
        CHECK(warehouse_type IN ('BACKROOM','SALES_FLOOR','COLD_STORAGE','OTHER')),
      is_sellable INTEGER NOT NULL DEFAULT 0 CHECK(is_sellable IN (0,1)),
      is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0,1)),
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(branch_id, code),
      FOREIGN KEY(branch_id) REFERENCES branches(id)
    )''',
    '''CREATE TABLE IF NOT EXISTS aisle_shelf_locations (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      warehouse_id TEXT NOT NULL, code TEXT NOT NULL, name_ar TEXT NOT NULL,
      location_type TEXT NOT NULL DEFAULT 'SHELF'
        CHECK(location_type IN ('AISLE','SHELF','FRIDGE','FREEZER','DISPLAY','OTHER')),
      is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0,1)),
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(branch_id, warehouse_id, code),
      FOREIGN KEY(branch_id, warehouse_id) REFERENCES warehouses(branch_id, id)
    )''',
    '''CREATE TABLE IF NOT EXISTS fridge_temp_logs (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      warehouse_id TEXT NOT NULL, location_id TEXT,
      temperature_c TEXT NOT NULL, measured_at TEXT NOT NULL,
      recorded_by_user_id TEXT, note TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id),
      FOREIGN KEY(branch_id, warehouse_id) REFERENCES warehouses(branch_id, id),
      FOREIGN KEY(branch_id, location_id) REFERENCES aisle_shelf_locations(branch_id, id),
      FOREIGN KEY(recorded_by_user_id, branch_id) REFERENCES users(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS purchase_orders (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      order_no TEXT NOT NULL, supplier_party_id TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'DRAFT'
        CHECK(status IN ('DRAFT','APPROVED','PARTIALLY_RECEIVED','RECEIVED','CANCELLED')),
      order_date TEXT NOT NULL, expected_date TEXT, notes TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(branch_id, order_no),
      FOREIGN KEY(supplier_party_id, branch_id) REFERENCES parties(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS purchase_order_items (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      purchase_order_id TEXT NOT NULL, product_id TEXT NOT NULL, unit_id TEXT,
      qty_ordered TEXT NOT NULL, conversion_factor TEXT NOT NULL,
      expected_unit_price TEXT NOT NULL DEFAULT '0.0000', notes TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id),
      FOREIGN KEY(branch_id, purchase_order_id) REFERENCES purchase_orders(branch_id, id),
      FOREIGN KEY(product_id, branch_id) REFERENCES products(id, branch_id),
      FOREIGN KEY(unit_id, branch_id) REFERENCES product_units_barcodes(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS purchase_invoices (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      invoice_no TEXT NOT NULL, supplier_invoice_no TEXT,
      supplier_party_id TEXT NOT NULL, warehouse_id TEXT NOT NULL,
      purchase_order_id TEXT, invoice_date TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'DRAFT'
        CHECK(status IN ('DRAFT','POSTED','VOIDED','RETURNED')),
      subtotal TEXT NOT NULL DEFAULT '0.0000', discount_amount TEXT NOT NULL DEFAULT '0.0000',
      net_total TEXT NOT NULL DEFAULT '0.0000', paid_total TEXT NOT NULL DEFAULT '0.0000',
      cash_account_id TEXT, payment_method TEXT NOT NULL DEFAULT 'CREDIT',
      wallet_ref_no TEXT, journal_entry_id TEXT, operation_id TEXT NOT NULL,
      notes TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(branch_id, invoice_no), UNIQUE(branch_id, operation_id),
      FOREIGN KEY(supplier_party_id, branch_id) REFERENCES parties(id, branch_id),
      FOREIGN KEY(branch_id, warehouse_id) REFERENCES warehouses(branch_id, id),
      FOREIGN KEY(branch_id, purchase_order_id) REFERENCES purchase_orders(branch_id, id),
      FOREIGN KEY(cash_account_id, branch_id) REFERENCES cash_accounts(id, branch_id),
      FOREIGN KEY(journal_entry_id, branch_id) REFERENCES journal_entries(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS purchase_invoice_items (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      purchase_invoice_id TEXT NOT NULL, product_id TEXT NOT NULL, unit_id TEXT,
      qty_paid TEXT NOT NULL, bonus_qty TEXT NOT NULL DEFAULT '0.0000',
      conversion_factor TEXT NOT NULL, purchase_unit_price TEXT NOT NULL,
      line_discount_amount TEXT NOT NULL DEFAULT '0.0000', line_total TEXT NOT NULL,
      total_base_units_added TEXT NOT NULL, effective_pack_cost TEXT NOT NULL,
      effective_base_cost TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(id, branch_id),
      FOREIGN KEY(branch_id, purchase_invoice_id) REFERENCES purchase_invoices(branch_id, id),
      FOREIGN KEY(product_id, branch_id) REFERENCES products(id, branch_id),
      FOREIGN KEY(unit_id, branch_id) REFERENCES product_units_barcodes(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS product_batches_fefo (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      product_id TEXT NOT NULL, warehouse_id TEXT NOT NULL, location_id TEXT,
      purchase_invoice_item_id TEXT, batch_no TEXT NOT NULL, expiry_date TEXT NOT NULL,
      pack_conversion_factor TEXT NOT NULL, sealed_cartons INTEGER NOT NULL DEFAULT 0,
      loose_base_qty TEXT NOT NULL DEFAULT '0.000000', total_base_qty TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'ACTIVE'
        CHECK(status IN ('ACTIVE','HOLD','EXPIRED','DEPLETED')),
      unit_cost_base TEXT NOT NULL DEFAULT '0.000000',
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(id, branch_id), UNIQUE(branch_id, product_id, warehouse_id, batch_no),
      FOREIGN KEY(product_id, branch_id) REFERENCES products(id, branch_id),
      FOREIGN KEY(branch_id, warehouse_id) REFERENCES warehouses(branch_id, id),
      FOREIGN KEY(branch_id, location_id) REFERENCES aisle_shelf_locations(branch_id, id),
      FOREIGN KEY(purchase_invoice_item_id, branch_id) REFERENCES purchase_invoice_items(id, branch_id),
      CHECK(sealed_cartons >= 0)
    )''',
    '''CREATE TABLE IF NOT EXISTS sales_invoice_item_batches (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      sales_invoice_item_id TEXT NOT NULL, product_batch_id TEXT NOT NULL,
      qty_base TEXT NOT NULL, cartons_opened INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id),
      FOREIGN KEY(sales_invoice_item_id, branch_id) REFERENCES sales_invoice_items(id, branch_id),
      FOREIGN KEY(product_batch_id, branch_id) REFERENCES product_batches_fefo(id, branch_id),
      CHECK(cartons_opened >= 0)
    )''',
    '''CREATE TABLE IF NOT EXISTS stocktaking_sessions (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      warehouse_id TEXT NOT NULL, session_no TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'DRAFT'
        CHECK(status IN ('DRAFT','COUNTING','APPROVED','CANCELLED')),
      blind_count INTEGER NOT NULL DEFAULT 1 CHECK(blind_count IN (0,1)),
      started_at TEXT NOT NULL, completed_at TEXT, approved_at TEXT,
      approved_by_user_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(branch_id, session_no),
      FOREIGN KEY(branch_id, warehouse_id) REFERENCES warehouses(branch_id, id),
      FOREIGN KEY(approved_by_user_id, branch_id) REFERENCES users(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS stocktaking_lines (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      session_id TEXT NOT NULL, product_id TEXT NOT NULL, product_batch_id TEXT,
      expected_base_qty TEXT NOT NULL DEFAULT '0.000000',
      counted_sealed_cartons INTEGER NOT NULL DEFAULT 0,
      counted_loose_base_qty TEXT NOT NULL DEFAULT '0.000000',
      pack_conversion_factor TEXT NOT NULL,
      counted_base_qty TEXT NOT NULL, variance_base_qty TEXT NOT NULL,
      counted_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id),
      FOREIGN KEY(branch_id, session_id) REFERENCES stocktaking_sessions(branch_id, id),
      FOREIGN KEY(product_id, branch_id) REFERENCES products(id, branch_id),
      FOREIGN KEY(product_batch_id, branch_id) REFERENCES product_batches_fefo(id, branch_id),
      CHECK(counted_sealed_cartons >= 0)
    )''',
    '''CREATE TABLE IF NOT EXISTS disposals (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      warehouse_id TEXT NOT NULL, disposal_no TEXT NOT NULL,
      reason TEXT NOT NULL CHECK(reason IN ('EXPIRED','DAMAGED','CONTAMINATED','OTHER')),
      status TEXT NOT NULL DEFAULT 'DRAFT' CHECK(status IN ('DRAFT','APPROVED','CANCELLED')),
      disposal_date TEXT NOT NULL, approved_by_user_id TEXT, notes TEXT NOT NULL DEFAULT '',
      journal_entry_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(branch_id, disposal_no),
      FOREIGN KEY(branch_id, warehouse_id) REFERENCES warehouses(branch_id, id),
      FOREIGN KEY(approved_by_user_id, branch_id) REFERENCES users(id, branch_id),
      FOREIGN KEY(journal_entry_id, branch_id) REFERENCES journal_entries(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS disposal_items (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      disposal_id TEXT NOT NULL, product_batch_id TEXT NOT NULL,
      qty_base TEXT NOT NULL, unit_cost_base TEXT NOT NULL,
      reason_note TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1, UNIQUE(branch_id, id),
      FOREIGN KEY(branch_id, disposal_id) REFERENCES disposals(branch_id, id),
      FOREIGN KEY(product_batch_id, branch_id) REFERENCES product_batches_fefo(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS stock_transfers (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      transfer_no TEXT NOT NULL, source_warehouse_id TEXT NOT NULL,
      destination_warehouse_id TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'DRAFT'
        CHECK(status IN ('DRAFT','APPROVED','IN_TRANSIT','RECEIVED','CANCELLED')),
      transfer_date TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(branch_id, transfer_no),
      CHECK(source_warehouse_id <> destination_warehouse_id),
      FOREIGN KEY(branch_id, source_warehouse_id) REFERENCES warehouses(branch_id, id),
      FOREIGN KEY(branch_id, destination_warehouse_id) REFERENCES warehouses(branch_id, id)
    )''',
    '''CREATE TABLE IF NOT EXISTS stock_transfer_items (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      transfer_id TEXT NOT NULL, product_batch_id TEXT NOT NULL,
      qty_base TEXT NOT NULL, cartons_moved INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1, UNIQUE(branch_id, id),
      FOREIGN KEY(branch_id, transfer_id) REFERENCES stock_transfers(branch_id, id),
      FOREIGN KEY(product_batch_id, branch_id) REFERENCES product_batches_fefo(id, branch_id),
      CHECK(cartons_moved >= 0)
    )''',
    '''CREATE TABLE IF NOT EXISTS purchase_returns (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      return_no TEXT NOT NULL, purchase_invoice_id TEXT NOT NULL,
      supplier_party_id TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'DRAFT' CHECK(status IN ('DRAFT','POSTED','CANCELLED')),
      return_date TEXT NOT NULL, net_total TEXT NOT NULL, journal_entry_id TEXT,
      operation_id TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, id), UNIQUE(branch_id, return_no), UNIQUE(branch_id, operation_id),
      FOREIGN KEY(branch_id, purchase_invoice_id) REFERENCES purchase_invoices(branch_id, id),
      FOREIGN KEY(supplier_party_id, branch_id) REFERENCES parties(id, branch_id),
      FOREIGN KEY(journal_entry_id, branch_id) REFERENCES journal_entries(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS purchase_return_items (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      purchase_return_id TEXT NOT NULL, purchase_invoice_item_id TEXT NOT NULL,
      product_batch_id TEXT NOT NULL, qty_base TEXT NOT NULL, line_total TEXT NOT NULL,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1, UNIQUE(branch_id, id),
      FOREIGN KEY(branch_id, purchase_return_id) REFERENCES purchase_returns(branch_id, id),
      FOREIGN KEY(purchase_invoice_item_id, branch_id) REFERENCES purchase_invoice_items(id, branch_id),
      FOREIGN KEY(product_batch_id, branch_id) REFERENCES product_batches_fefo(id, branch_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS price_cost_history (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      product_id TEXT NOT NULL, unit_id TEXT,
      source_type TEXT NOT NULL
        CHECK(source_type IN ('PURCHASE','PURCHASE_RETURN','MANUAL_ADJUSTMENT','OPENING')),
      source_id TEXT NOT NULL, old_cost_base TEXT NOT NULL, new_cost_base TEXT NOT NULL,
      effective_at TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL DEFAULT 'LOCAL',
      sync_version INTEGER NOT NULL DEFAULT 1, UNIQUE(branch_id, id),
      FOREIGN KEY(product_id, branch_id) REFERENCES products(id, branch_id),
      FOREIGN KEY(unit_id, branch_id) REFERENCES product_units_barcodes(id, branch_id)
    )''',
  ];

  static const List<String> _indexes = [
    'CREATE INDEX IF NOT EXISTS idx_batches_fefo ON product_batches_fefo(branch_id, product_id, status, expiry_date, created_at)',
    'CREATE INDEX IF NOT EXISTS idx_batches_warehouse ON product_batches_fefo(branch_id, warehouse_id, product_id)',
    'CREATE INDEX IF NOT EXISTS idx_purchase_invoice_supplier ON purchase_invoices(branch_id, supplier_party_id, invoice_date)',
    'CREATE INDEX IF NOT EXISTS idx_stocktaking_status ON stocktaking_sessions(branch_id, status, started_at)',
    'CREATE INDEX IF NOT EXISTS idx_fridge_logs_date ON fridge_temp_logs(branch_id, location_id, measured_at)',
    'CREATE INDEX IF NOT EXISTS idx_stock_transfer_status ON stock_transfers(branch_id, status, transfer_date)',
  ];
}
