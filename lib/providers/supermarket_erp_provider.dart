import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../data/database/database_helper.dart';
import '../data/models/erp_and_sync_models.dart';

/// Holds the authenticated local session and executive/accounting dashboard state.
class SupermarketErpProvider extends ChangeNotifier {
  SupermarketErpProvider({DatabaseHelper? databaseHelper})
      : _helper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _helper;
  Map<String, Object?>? _currentUser;
  Map<String, Object?>? get currentUser => _currentUser;
  bool _loading = false;
  bool get isLoading => _loading;
  String? _error;
  String? get error => _error;

  Map<String, double> _dashboard = const {};
  Map<String, double> get dashboard => _dashboard;
  Map<String, double> _paymentTotalsByMethod = const {};
  Map<String, double> get paymentTotalsByMethod => _paymentTotalsByMethod;
  List<PartyModel> _parties = [];
  List<PartyModel> get parties => List.unmodifiable(_parties);
  List<VoucherModel> _vouchers = [];
  List<VoucherModel> get vouchers => List.unmodifiable(_vouchers);
  FirebaseQuotaModel? _quota;
  FirebaseQuotaModel? get quota => _quota;

  /// Verifies a development account against its stored SHA-256 password hash.
  Future<bool> signIn(String username, String password) async {
    _setLoading(true);
    try {
      final db = await _helper.database;
      final digest = sha256.convert(utf8.encode(password)).toString();
      final rows = await db.query('users',
        where: 'username=? AND password_hash=? AND is_active=1 AND is_deleted=0',
        whereArgs: [username.trim(), digest], limit: 1);
      if (rows.isEmpty) {
        _error = 'اسم المستخدم أو كلمة المرور غير صحيحة';
        return false;
      }
      _currentUser = rows.first;
      _error = null;
      await loadDashboard();
      await loadParties();
      await loadVouchers();
      await loadQuota();
      return true;
    } catch (error) {
      _error = 'تعذر تسجيل الدخول: $error';
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Clears the active local session.
  void signOut() {
    _currentUser = null;
    _dashboard = const {};
    _parties = [];
    _vouchers = [];
    notifyListeners();
  }

  /// Loads branch totals from local records without making network requests.
  Future<void> loadDashboard() async {
    final user = _currentUser;
    if (user == null) return;
    final branchId = user['branch_id'] as String?;
    if (branchId == null) return;
    final db = await _helper.database;
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).toIso8601String();
    final end = DateTime(now.year, now.month, now.day, 23, 59, 59).toIso8601String();
    final sales = await db.rawQuery(
      '''SELECT COUNT(*) AS count, COALESCE(SUM(net_total),0) AS total,
         COALESCE(SUM(remaining_alayh),0) AS credit
         FROM sales_invoices WHERE branch_id=? AND status='COMPLETED'
         AND invoice_date BETWEEN ? AND ? AND is_deleted=0''',
      [branchId, start, end]);
    final cash = await db.rawQuery(
      'SELECT COALESCE(SUM(current_balance),0) AS total FROM cash_accounts WHERE branch_id=? AND is_deleted=0',
      [branchId]);
    final partyTotals = await db.rawQuery(
      '''SELECT p.party_type,
         COALESCE(SUM(CASE WHEN b.net > 0 THEN b.net ELSE 0 END),0) AS alayh_total,
         COALESCE(SUM(CASE WHEN b.net < 0 THEN -b.net ELSE 0 END),0) AS lah_total
         FROM parties p JOIN v_party_balance b ON b.party_id=p.id
         WHERE p.branch_id=? AND p.is_deleted=0
         GROUP BY p.party_type''',
      [branchId]);
    var customerAlayh = 0.0;
    var supplierLah = 0.0;
    for (final row in partyTotals) {
      if (row['party_type'] == 'CUSTOMER') {
        customerAlayh += (row['alayh_total'] as num).toDouble();
      }
      if (row['party_type'] == 'SUPPLIER') {
        supplierLah += (row['lah_total'] as num).toDouble();
      }
    }
    final accountRows = await db.query(
      'cash_accounts',
      columns: ['account_kind', 'wallet_provider', 'current_balance'],
      where: 'branch_id=? AND is_deleted=0',
      whereArgs: [branchId],
    );
    var cashDrawer = 0.0, jawali = 0.0, jeeb = 0.0, floosak = 0.0, kuraimi = 0.0;
    for (final row in accountRows) {
      final amount = (row['current_balance'] as num? ?? 0).toDouble();
      switch (row['wallet_provider']) {
        case 'JAWALI':
          jawali += amount;
          break;
        case 'JAIB':
        case 'JEEB':
          jeeb += amount;
          break;
        case 'FLOUSK':
        case 'FLOOSAK':
          floosak += amount;
          break;
        case 'KURAIMI':
          kuraimi += amount;
          break;
        default:
          cashDrawer += amount;
      }
    }
    final paymentRows = await db.rawQuery(
      '''SELECT sp.method, COALESCE(SUM(sp.amount),0) AS total
         FROM sales_payments sp
         JOIN sales_invoices si ON si.id=sp.invoice_id
         WHERE si.branch_id=? AND si.status='COMPLETED'
           AND si.invoice_date BETWEEN ? AND ? AND si.is_deleted=0
         GROUP BY sp.method''',
      [branchId, start, end]);
    _paymentTotalsByMethod = {
      for (final row in paymentRows)
        row['method'] as String: (row['total'] as num).toDouble(),
    };
    final stock = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM products WHERE branch_id=? AND is_active=1 AND is_deleted=0 AND stock_base_qty<=min_stock_alert_qty',
      [branchId]);
    _dashboard = {
      'salesCount': (sales.first['count'] as num).toDouble(),
      'salesTotal': (sales.first['total'] as num).toDouble(),
      'creditTotal': customerAlayh,
      'supplierTotal': supplierLah,
      'cashTotal': (cash.first['total'] as num).toDouble(),
      'cashDrawer': cashDrawer,
      'jawali': jawali,
      'jeeb': jeeb,
      'floosak': floosak,
      'kuraimi': kuraimi,
      'stockAlerts': (stock.first['count'] as num).toDouble(),
    };
    notifyListeners();
  }

  /// Loads active customers and suppliers for account screens.
  Future<void> loadParties() async {
    final db = await _helper.database;
    final rows = await db.query('parties',
      where: 'is_deleted=0', orderBy: 'name_ar COLLATE NOCASE');
    _parties = rows.map(PartyModel.fromMap).toList();
    notifyListeners();
  }

  /// Loads the most recent receipts and payments.
  Future<void> loadVouchers({int limit = 100}) async {
    final db = await _helper.database;
    final rows = await db.query('vouchers',
      where: 'is_deleted=0', orderBy: 'voucher_date DESC', limit: limit);
    _vouchers = rows.map((row) => VoucherModel(
      id: row['id'] as String,
      voucherNo: row['voucher_no'] as String,
      voucherType: row['voucher_type'] as String,
      voucherDate: row['voucher_date'] as String,
      partyId: row['party_id'] as String?,
      cashAccountId: row['cash_account_id'] as String?,
      amount: (row['amount'] as num).toDouble(),
      method: row['method'] as String,
      walletRefNo: row['wallet_ref_no'] as String?,
      description: row['description'] as String?,
      journalEntryId: row['journal_entry_id'] as String?,
    )).toList();
    notifyListeners();
  }

  /// Reads the local quota estimate for the current date.
  Future<void> loadQuota() async {
    final db = await _helper.database;
    final now = DateTime.now();
    final dateKey = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final rows = await db.query('firebase_quota_tracker',
      where: 'date_key=?', whereArgs: [dateKey], limit: 1);
    if (rows.isEmpty) {
      _quota = FirebaseQuotaModel(dateKey: dateKey);
    } else {
      final row = rows.first;
      _quota = FirebaseQuotaModel(
        dateKey: dateKey,
        writesUsed: (row['writes_used'] as num).toInt(),
        readsUsed: (row['reads_used'] as num).toInt(),
        deletesUsed: (row['deletes_used'] as num).toInt(),
        maxDailyWritesLimit: (row['max_daily_writes_limit'] as num).toInt(),
      );
    }
    notifyListeners();
  }

  void _setLoading(bool value) {
    _loading = value;
    notifyListeners();
  }
}