import 'package:sqflite/sqflite.dart';

/// Inserts deterministic development fixtures for a fresh local database.
class SeedData {
  SeedData._();

  static const String branchId = 'branch-main';
  static const String ownerId = 'user-owner';

  /// Seeds the initial branch, development user, accounts, parties and eight products.
  static Future<void> seed(DatabaseExecutor db) async {
    final now = DateTime.now().toIso8601String();
    Map<String, Object?> base(String id) => {
      'id': id, 'uuid': 'uuid-$id', 'branch_id': branchId,
      'created_at': now, 'updated_at': now, 'is_deleted': 0,
      'sync_status': 'LOCAL', 'sync_version': 1,
    };

    final branch = base(branchId)
      ..addAll({
        'branch_id': null, 'code': 'MAIN', 'name_ar': 'الفرع الرئيسي',
        'address': '', 'phone': '', 'tax_no': '', 'is_main': 1,
      });
    await db.insert('branches', branch, conflictAlgorithm: ConflictAlgorithm.ignore);

    final user = base(ownerId)
      ..addAll({
        'username': 'admin', 'full_name': 'مدير النظام',
        'role_code': 'OWNER',
        'password_hash': '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92',
        'manager_pin_hash': '888df25ae35772424a560c7152a1de794440e0ea5cfee62828333a456a506e05',
        'max_discount_pct': 10, 'is_active': 1,
      });
    await db.insert('users', user, conflictAlgorithm: ConflictAlgorithm.ignore);

    final accounts = <Map<String, Object?>>[
      {'id':'gl-cash','code':'1101','name_ar':'الصندوق','account_type':'ASSET'},
      {'id':'gl-wallet','code':'1102','name_ar':'المحافظ الإلكترونية','account_type':'ASSET'},
      {'id':'gl-receivable','code':'1201','name_ar':'حسابات العملاء','account_type':'ASSET'},
      {'id':'gl-payable','code':'2101','name_ar':'حسابات الموردين','account_type':'LIABILITY'},
      {'id':'gl-sales','code':'4101','name_ar':'المبيعات','account_type':'REVENUE'},
      {'id':'gl-inventory','code':'1301','name_ar':'المخزون','account_type':'ASSET'},
      {'id':'gl-cogs','code':'5101','name_ar':'تكلفة البضاعة المباعة','account_type':'EXPENSE'},
    ];
    for (final account in accounts) {
      await db.insert('chart_of_accounts', {
        ...base(account['id']! as String),
        ...account,
        'parent_id': null, 'is_active': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final cashAccounts = <Map<String, Object?>>[
      {'id':'cash-drawer','code':'CASH','name_ar':'درج الكاشير','account_kind':'CASHIER_DRAWER','wallet_provider':null},
      {'id':'wallet-jawali','code':'JAWALI','name_ar':'محفظة جوالي','account_kind':'WALLET','wallet_provider':'JAWALI'},
      {'id':'wallet-jaib','code':'JAIB','name_ar':'محفظة جيب','account_kind':'WALLET','wallet_provider':'JAIB'},
      {'id':'wallet-flousk','code':'FLOUSK','name_ar':'محفظة فلوسك','account_kind':'WALLET','wallet_provider':'FLOUSK'},
      {'id':'wallet-kuraimi','code':'KURAIMI','name_ar':'محفظة كريمي','account_kind':'WALLET','wallet_provider':'KURAIMI'},
    ];
    for (final account in cashAccounts) {
      await db.insert('cash_accounts', {
        ...base(account['id']! as String),
        ...account,
        'wallet_phone': null,
        'gl_account_id': account['account_kind'] == 'CASHIER_DRAWER' ? 'gl-cash' : 'gl-wallet',
        'current_balance': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final parties = <Map<String, Object?>>[
      {'id':'customer-retail','party_type':'CUSTOMER','code':'C001','name_ar':'زبون الحارة','price_tier':'RETAIL'},
      {'id':'customer-wholesale','party_type':'CUSTOMER','code':'C002','name_ar':'تاجر الجملة','price_tier':'WHOLESALE'},
      {'id':'supplier-1','party_type':'SUPPLIER','code':'S001','name_ar':'مورد المواد الغذائية','price_tier':'WHOLESALE'},
      {'id':'supplier-2','party_type':'SUPPLIER','code':'S002','name_ar':'مورد الألبان','price_tier':'WHOLESALE'},
    ];
    for (final party in parties) {
      await db.insert('parties', {
        ...base(party['id']! as String),
        ...party,
        'phone': null, 'address': null, 'credit_limit': party['id'] == 'customer-retail' ? 50000 : 0,
        'payment_terms_days': 30, 'is_blocked': 0, 'opening_alayh': 0, 'opening_lah': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    await db.insert('product_categories', {
      ...base('cat-grocery'), 'parent_id': null, 'code': 'GROC',
      'name_ar': 'مواد غذائية', 'aisle_location': 'A1', 'is_active': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    final products = <Map<String, Object?>>[
      {'id':'p-rice','sku_code':'1001','name_ar':'أرز بسمتي','base_unit_name':'جرام','stock_base_qty':500000,'product_type':'STANDARD'},
      {'id':'p-milk','sku_code':'1002','name_ar':'حليب سائل','base_unit_name':'حبة','stock_base_qty':240,'product_type':'STANDARD'},
      {'id':'p-oil','sku_code':'1003','name_ar':'زيت طبخ','base_unit_name':'ملليلتر','stock_base_qty':120000,'product_type':'STANDARD'},
      {'id':'p-sugar','sku_code':'1004','name_ar':'سكر','base_unit_name':'جرام','stock_base_qty':200000,'product_type':'STANDARD'},
      {'id':'p-flour','sku_code':'1005','name_ar':'دقيق','base_unit_name':'جرام','stock_base_qty':300000,'product_type':'STANDARD'},
      {'id':'p-tea','sku_code':'1006','name_ar':'شاي','base_unit_name':'جرام','stock_base_qty':50000,'product_type':'STANDARD'},
      {'id':'p-cheese','sku_code':'1007','name_ar':'جبن رومي موزون','base_unit_name':'جرام','stock_base_qty':25000,'product_type':'WEIGHTED_SCALE'},
      {'id':'p-water','sku_code':'1008','name_ar':'مياه شرب','base_unit_name':'حبة','stock_base_qty':300,'product_type':'STANDARD'},
    ];
    for (final product in products) {
      final row = <String, Object?>{
        ...base(product['id']! as String),
        ...product,
        'name_en': null, 'category_id': 'cat-grocery', 'brand_name': null,
        'scale_plu_code': product['id'] == 'p-cheese' ? '1025' : null,
        'avg_cost_base_unit': 0, 'last_cost_base_unit': 0,
        'min_stock_alert_qty': 5, 'reorder_qty': 20,
        'has_expiry_date': 0, 'nearest_expiry_date': null,
        'tax_rate_pct': 0, 'is_active': 1,
      };
      await db.insert('products', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final units = <Map<String, Object?>>[
      {'id':'u-rice-sack','product_id':'p-rice','unit_name':'شوال 10 كيلو','conversion_factor':10000,'barcode':'6281000001001','cost_price':4500,'retail_price':5500,'wholesale_price':5100},
      {'id':'u-milk-piece','product_id':'p-milk','unit_name':'حبة','conversion_factor':1,'barcode':'6281000001002','cost_price':250,'retail_price':300,'wholesale_price':275},
      {'id':'u-milk-pack','product_id':'p-milk','unit_name':'باكت 6','conversion_factor':6,'barcode':'6281000001102','cost_price':1450,'retail_price':1700,'wholesale_price':1550},
      {'id':'u-milk-carton','product_id':'p-milk','unit_name':'كرتون 24','conversion_factor':24,'barcode':'6281000001202','cost_price':5700,'retail_price':6600,'wholesale_price':6200},
      {'id':'u-oil-bottle','product_id':'p-oil','unit_name':'قارورة لتر','conversion_factor':1000,'barcode':'6281000001003','cost_price':800,'retail_price':1000,'wholesale_price':900},
      {'id':'u-sugar-kg','product_id':'p-sugar','unit_name':'كيلو','conversion_factor':1000,'barcode':'6281000001004','cost_price':500,'retail_price':650,'wholesale_price':580},
      {'id':'u-flour-kg','product_id':'p-flour','unit_name':'كيلو','conversion_factor':1000,'barcode':'6281000001005','cost_price':400,'retail_price':550,'wholesale_price':490},
      {'id':'u-tea-pack','product_id':'p-tea','unit_name':'علبة','conversion_factor':100,'barcode':'6281000001006','cost_price':600,'retail_price':750,'wholesale_price':680},
      {'id':'u-cheese-kg','product_id':'p-cheese','unit_name':'كيلو','conversion_factor':1000,'barcode':null,'cost_price':3000,'retail_price':3800,'wholesale_price':3500},
      {'id':'u-water-piece','product_id':'p-water','unit_name':'حبة','conversion_factor':1,'barcode':'6281000001008','cost_price':80,'retail_price':100,'wholesale_price':90},
    ];
    for (final unit in units) {
      await db.insert('product_units_barcodes', {
        ...base(unit['id']! as String),
        ...unit,
        'min_sell_price': unit['retail_price'],
        'is_default_pos_unit': unit['id'] == 'u-milk-piece' || unit['id'] == 'u-cheese-kg' ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
}