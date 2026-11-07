import 'package:sqflite/sqflite.dart';

/// Owns the version-one SQLite schema, indexes and derived balance view.
class SchemaBuilder {
  SchemaBuilder._();

  static const int version = 1;

  /// Creates all tables in dependency order inside the caller's database transaction.
  static Future<void> createAll(DatabaseExecutor database) async {
    for (final sql in _tables) {
      await database.execute(sql);
    }
    for (final sql in _indexes) {
      await database.execute(sql);
    }
    await database.execute(_partyBalanceView);
  }

  static const List<String> _tables = [
    '''CREATE TABLE branches (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT,
      code TEXT NOT NULL UNIQUE, name_ar TEXT NOT NULL, address TEXT, phone TEXT,
      tax_no TEXT, is_main INTEGER NOT NULL DEFAULT 0 CHECK(is_main IN (0,1)),
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1
    )''',
    '''CREATE TABLE users (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT,
      username TEXT NOT NULL UNIQUE, full_name TEXT NOT NULL,
      role_code TEXT NOT NULL CHECK(role_code IN ('OWNER','MANAGER','CASHIER','STOREKEEPER','ACCOUNTANT')),
      password_hash TEXT NOT NULL, manager_pin_hash TEXT,
      max_discount_pct REAL NOT NULL DEFAULT 0, is_active INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1
    )''',
    '''CREATE TABLE number_sequences (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      doc_type TEXT NOT NULL, prefix TEXT NOT NULL DEFAULT '', year INTEGER NOT NULL,
      last_no INTEGER NOT NULL DEFAULT 0, pad_length INTEGER NOT NULL DEFAULT 6,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, doc_type, year)
    )''',
    '''CREATE TABLE sync_queue (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      table_name TEXT NOT NULL, row_uuid TEXT NOT NULL, operation TEXT NOT NULL
        CHECK(operation IN ('INSERT','UPDATE','SOFT_DELETE')),
      payload_json TEXT NOT NULL, sync_version INTEGER NOT NULL DEFAULT 1,
      batch_id TEXT, status TEXT NOT NULL DEFAULT 'PENDING'
        CHECK(status IN ('PENDING','BATCHED_SENT','FAILED')),
      queued_at TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0
    )''',
    '''CREATE TABLE firebase_quota_tracker (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      date_key TEXT NOT NULL UNIQUE, writes_used INTEGER NOT NULL DEFAULT 0,
      reads_used INTEGER NOT NULL DEFAULT 0, deletes_used INTEGER NOT NULL DEFAULT 0,
      max_daily_writes_limit INTEGER NOT NULL DEFAULT 18000,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1
    )''',
    '''CREATE TABLE product_categories (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      parent_id TEXT, code TEXT NOT NULL, name_ar TEXT NOT NULL, aisle_location TEXT,
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(parent_id) REFERENCES product_categories(id)
    )''',
    '''CREATE TABLE products (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      sku_code TEXT NOT NULL UNIQUE, name_ar TEXT NOT NULL, name_en TEXT,
      category_id TEXT, brand_name TEXT,
      product_type TEXT NOT NULL DEFAULT 'STANDARD'
        CHECK(product_type IN ('STANDARD','WEIGHTED_SCALE','SERVICE')),
      scale_plu_code TEXT, base_unit_name TEXT NOT NULL,
      stock_base_qty REAL NOT NULL DEFAULT 0,
      avg_cost_base_unit REAL NOT NULL DEFAULT 0, last_cost_base_unit REAL NOT NULL DEFAULT 0,
      min_stock_alert_qty REAL NOT NULL DEFAULT 0, reorder_qty REAL NOT NULL DEFAULT 0,
      has_expiry_date INTEGER NOT NULL DEFAULT 0, nearest_expiry_date TEXT,
      tax_rate_pct REAL NOT NULL DEFAULT 0, is_active INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(category_id) REFERENCES product_categories(id)
    )''',
    '''CREATE TABLE product_units_barcodes (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      product_id TEXT NOT NULL, unit_name TEXT NOT NULL,
      conversion_factor REAL NOT NULL CHECK(conversion_factor >= 0.001),
      barcode TEXT UNIQUE, cost_price REAL NOT NULL DEFAULT 0,
      retail_price REAL NOT NULL DEFAULT 0, wholesale_price REAL NOT NULL DEFAULT 0,
      min_sell_price REAL NOT NULL DEFAULT 0,
      is_default_pos_unit INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(product_id) REFERENCES products(id)
    )''',
    '''CREATE TABLE parties (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      party_type TEXT NOT NULL CHECK(party_type IN ('CUSTOMER','SUPPLIER','EMPLOYEE','PARTNER','REPRESENTATIVE')),
      code TEXT NOT NULL, name_ar TEXT NOT NULL, phone TEXT, address TEXT,
      credit_limit REAL NOT NULL DEFAULT 0, payment_terms_days INTEGER NOT NULL DEFAULT 0,
      price_tier TEXT NOT NULL DEFAULT 'RETAIL' CHECK(price_tier IN ('RETAIL','WHOLESALE')),
      is_blocked INTEGER NOT NULL DEFAULT 0, opening_alayh REAL NOT NULL DEFAULT 0,
      opening_lah REAL NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, code)
    )''',
    '''CREATE TABLE chart_of_accounts (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      code TEXT NOT NULL, name_ar TEXT NOT NULL, account_type TEXT NOT NULL,
      parent_id TEXT, is_active INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(parent_id) REFERENCES chart_of_accounts(id), UNIQUE(branch_id, code)
    )''',
    '''CREATE TABLE journal_entries (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      entry_no TEXT NOT NULL, entry_date TEXT NOT NULL, doc_type TEXT NOT NULL,
      doc_id TEXT NOT NULL, description TEXT NOT NULL,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      UNIQUE(branch_id, entry_no)
    )''',
    '''CREATE TABLE journal_lines (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      journal_entry_id TEXT NOT NULL, gl_account_id TEXT NOT NULL,
      dr_amount REAL NOT NULL DEFAULT 0 CHECK(dr_amount >= 0),
      cr_amount REAL NOT NULL DEFAULT 0 CHECK(cr_amount >= 0),
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      CHECK((dr_amount > 0 AND cr_amount = 0) OR (cr_amount > 0 AND dr_amount = 0)),
      FOREIGN KEY(journal_entry_id) REFERENCES journal_entries(id),
      FOREIGN KEY(gl_account_id) REFERENCES chart_of_accounts(id)
    )''',
    '''CREATE TABLE lah_alayh_ledger (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      party_id TEXT NOT NULL, entry_date TEXT NOT NULL, entry_type TEXT NOT NULL,
      alayh_amount REAL NOT NULL DEFAULT 0, lah_amount REAL NOT NULL DEFAULT 0,
      doc_type TEXT, doc_id TEXT, statement_ar TEXT, journal_entry_id TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      CHECK((alayh_amount > 0) <> (lah_amount > 0)),
      FOREIGN KEY(party_id) REFERENCES parties(id),
      FOREIGN KEY(journal_entry_id) REFERENCES journal_entries(id)
    )''',
    '''CREATE TABLE cash_accounts (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      code TEXT NOT NULL, name_ar TEXT NOT NULL,
      account_kind TEXT NOT NULL CHECK(account_kind IN ('CASHIER_DRAWER','MAIN_SAFE','WALLET','BANK')),
      wallet_provider TEXT CHECK(wallet_provider IN ('JAWALI','JAIB','FLOUSK','KURAIMI','OTHER')),
      wallet_phone TEXT, gl_account_id TEXT, current_balance REAL NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(gl_account_id) REFERENCES chart_of_accounts(id), UNIQUE(branch_id, code)
    )''',
    '''CREATE TABLE vouchers (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      voucher_no TEXT NOT NULL, voucher_type TEXT NOT NULL CHECK(voucher_type IN ('RECEIPT','PAYMENT','SETTLEMENT')),
      voucher_date TEXT NOT NULL, party_id TEXT, cash_account_id TEXT,
      amount REAL NOT NULL CHECK(amount > 0),
      method TEXT NOT NULL CHECK(method IN ('CASH','WALLET','BANK','OFFSET')),
      wallet_ref_no TEXT, description TEXT, journal_entry_id TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      CHECK(method != 'WALLET' OR (wallet_ref_no IS NOT NULL AND length(trim(wallet_ref_no)) > 0)),
      FOREIGN KEY(party_id) REFERENCES parties(id),
      FOREIGN KEY(cash_account_id) REFERENCES cash_accounts(id),
      FOREIGN KEY(journal_entry_id) REFERENCES journal_entries(id),
      UNIQUE(branch_id, voucher_no)
    )''',
    '''CREATE TABLE sales_invoices (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      invoice_no TEXT NOT NULL, invoice_date TEXT NOT NULL, cashier_user_id TEXT NOT NULL,
      customer_party_id TEXT, price_tier TEXT NOT NULL CHECK(price_tier IN ('RETAIL','WHOLESALE')),
      sale_type TEXT NOT NULL CHECK(sale_type IN ('CASH','CREDIT','MIXED')),
      status TEXT NOT NULL CHECK(status IN ('HELD','COMPLETED','VOIDED')),
      hold_label TEXT, subtotal REAL NOT NULL DEFAULT 0,
      discount_pct REAL NOT NULL DEFAULT 0, discount_amount REAL NOT NULL DEFAULT 0,
      rounding_diff REAL NOT NULL DEFAULT 0, net_total REAL NOT NULL DEFAULT 0,
      paid_total REAL NOT NULL DEFAULT 0, change_returned REAL NOT NULL DEFAULT 0,
      remaining_alayh REAL NOT NULL DEFAULT 0, total_cost REAL NOT NULL DEFAULT 0,
      journal_entry_id TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(cashier_user_id) REFERENCES users(id),
      FOREIGN KEY(customer_party_id) REFERENCES parties(id),
      FOREIGN KEY(journal_entry_id) REFERENCES journal_entries(id),
      UNIQUE(branch_id, invoice_no)
    )''',
    '''CREATE TABLE sales_invoice_items (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      invoice_id TEXT NOT NULL, product_id TEXT NOT NULL, unit_barcode_id TEXT,
      unit_name TEXT NOT NULL, conversion_factor REAL NOT NULL CHECK(conversion_factor > 0),
      qty_sold REAL NOT NULL CHECK(qty_sold > 0),
      base_qty_deducted REAL NOT NULL CHECK(base_qty_deducted > 0),
      unit_price REAL NOT NULL CHECK(unit_price >= 0),
      line_discount_amount REAL NOT NULL DEFAULT 0,
      line_total REAL NOT NULL CHECK(line_total >= 0), line_cost REAL NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(invoice_id) REFERENCES sales_invoices(id),
      FOREIGN KEY(product_id) REFERENCES products(id),
      FOREIGN KEY(unit_barcode_id) REFERENCES product_units_barcodes(id)
    )''',
    '''CREATE TABLE sales_payments (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      invoice_id TEXT NOT NULL, cash_account_id TEXT, method TEXT NOT NULL,
      amount REAL NOT NULL CHECK(amount > 0), wallet_ref_no TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      CHECK(method != 'WALLET' OR (wallet_ref_no IS NOT NULL AND length(trim(wallet_ref_no)) > 0)),
      FOREIGN KEY(invoice_id) REFERENCES sales_invoices(id),
      FOREIGN KEY(cash_account_id) REFERENCES cash_accounts(id)
    )''',
    '''CREATE TABLE stock_movements (
      id TEXT PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, branch_id TEXT NOT NULL,
      product_id TEXT NOT NULL, movement_date TEXT NOT NULL, movement_type TEXT NOT NULL,
      quantity_base REAL NOT NULL, unit_cost_base REAL NOT NULL DEFAULT 0,
      doc_type TEXT NOT NULL, doc_id TEXT NOT NULL,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'LOCAL', sync_version INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(product_id) REFERENCES products(id)
    )'''
  ];

  static const List<String> _indexes = [
    'CREATE INDEX idx_products_name ON products(name_ar)',
    'CREATE UNIQUE INDEX idx_products_scale_plu ON products(branch_id, scale_plu_code) WHERE scale_plu_code IS NOT NULL AND is_deleted = 0',
    'CREATE INDEX idx_unit_barcode ON product_units_barcodes(barcode)',
    'CREATE INDEX idx_ledger_party_date ON lah_alayh_ledger(party_id, entry_date)',
    'CREATE INDEX idx_sales_invoice_date ON sales_invoices(branch_id, invoice_date)',
    'CREATE INDEX idx_sync_queue_status ON sync_queue(status, queued_at)',
    'CREATE INDEX idx_stock_movements_product ON stock_movements(product_id, movement_date)',
    'CREATE INDEX idx_journal_lines_entry ON journal_lines(journal_entry_id)',
  ];

  static const String _partyBalanceView = '''
    CREATE VIEW v_party_balance AS
    SELECT p.id AS party_id,
      COALESCE(SUM(l.alayh_amount), 0) AS total_alayh,
      COALESCE(SUM(l.lah_amount), 0) AS total_lah,
      (COALESCE(SUM(l.alayh_amount), 0)) -
      (COALESCE(SUM(l.lah_amount), 0)) AS net,
      CASE
        WHEN (COALESCE(SUM(l.alayh_amount), 0)) >
             (COALESCE(SUM(l.lah_amount), 0)) THEN 'ALAYH'
        WHEN (COALESCE(SUM(l.lah_amount), 0)) >
             (COALESCE(SUM(l.alayh_amount), 0)) THEN 'LAH'
        ELSE 'ZERO'
      END AS balance_side,
      ABS((COALESCE(SUM(l.alayh_amount), 0)) -
          (COALESCE(SUM(l.lah_amount), 0))) AS balance_abs
    FROM parties p
    LEFT JOIN lah_alayh_ledger l ON l.party_id = p.id AND l.is_deleted = 0
    WHERE p.is_deleted = 0
    GROUP BY p.id
  ''';
}