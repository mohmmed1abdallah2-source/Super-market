import 'package:flutter/foundation.dart';
import '../data/database/database_helper.dart';
import '../data/models/erp_and_sync_models.dart';
import '../data/services/scale_pos_and_ledger_service.dart';
import '../data/services/scale_and_pos_service.dart';

/// Immutable party row joined to its ledger-derived totals.
class PartyBalanceRecord {
  /// Creates a party balance record.
  const PartyBalanceRecord({
    required this.party,
    required this.totalAlayh,
    required this.totalLah,
  });

  /// Party master data.
  final PartyModel party;

  /// Sum of alayh movements.
  final double totalAlayh;

  /// Sum of lah movements.
  final double totalLah;

  /// Absolute net balance.
  double get balanceAbs => (totalAlayh - totalLah).abs();

  /// ALAYH, LAH or ZERO.
  String get balanceSide => totalAlayh > totalLah
      ? 'ALAYH'
      : totalLah > totalAlayh
          ? 'LAH'
          : 'ZERO';
}

/// Coordinates POS posting, party balances, vouchers, cash accounts and sync.
class PosAndLedgerProvider extends ChangeNotifier {
  /// Creates the provider with a local database engine.
  PosAndLedgerProvider({DatabaseHelper? databaseHelper})
      : _helper = databaseHelper ?? DatabaseHelper.instance,
        _engine = LocalPosAndLedgerEngine(databaseHelper: databaseHelper);

  final DatabaseHelper _helper;
  final LocalPosAndLedgerEngine _engine;

  List<PartyBalanceRecord> _partyBalances = [];
  List<CashAccountModel> _cashAccounts = [];
  int _pendingSyncCount = 0;
  int _failedSyncCount = 0;
  bool _busy = false;
  String? _lastError;
  String _syncState = 'IDLE';

  /// Current party balances calculated from the local ledger view.
  List<PartyBalanceRecord> get partyBalances => List.unmodifiable(_partyBalances);

  /// Active cash drawers and electronic wallets.
  List<CashAccountModel> get cashAccounts => List.unmodifiable(_cashAccounts);

  /// Number of queued local operations.
  int get pendingSyncCount => _pendingSyncCount;

  /// Number of failed synchronization events.
  int get failedSyncCount => _failedSyncCount;

  /// Whether a posting or synchronization action is running.
  bool get isBusy => _busy;

  /// Last recoverable error.
  String? get lastError => _lastError;

  /// Current local synchronization state.
  String get syncState => _syncState;

  /// Loads party balances, cash accounts and sync queue counters.
  Future<void> refresh(String branchId) async {
    final db = await _helper.database;
    final partyRows = await db.rawQuery(
      '''SELECT p.*, COALESCE(b.total_alayh, 0) AS total_alayh,
                COALESCE(b.total_lah, 0) AS total_lah
         FROM parties p
         LEFT JOIN v_party_balance b ON b.party_id = p.id
         WHERE p.branch_id = ? AND p.is_deleted = 0
         ORDER BY p.name_ar COLLATE NOCASE''',
      [branchId],
    );
    _partyBalances = partyRows.map((row) => PartyBalanceRecord(
      party: PartyModel.fromMap(row),
      totalAlayh: (row['total_alayh'] as num? ?? 0).toDouble(),
      totalLah: (row['total_lah'] as num? ?? 0).toDouble(),
    )).toList(growable: false);

    final accountRows = await db.query(
      'cash_accounts',
      where: 'branch_id=? AND is_deleted=0',
      whereArgs: [branchId],
      orderBy: 'code',
    );
    _cashAccounts = accountRows.map((row) => CashAccountModel(
      id: row['id'] as String,
      code: row['code'] as String,
      nameAr: row['name_ar'] as String,
      accountKind: row['account_kind'] as String,
      walletProvider: row['wallet_provider'] as String?,
      walletPhone: row['wallet_phone'] as String?,
      glAccountId: row['gl_account_id'] as String?,
      currentBalance: (row['current_balance'] as num? ?? 0).toDouble(),
    )).toList(growable: false);

    final pending = await db.rawQuery(
      '''SELECT
        SUM(CASE WHEN status IN ('PENDING','FAILED') THEN 1 ELSE 0 END) AS pending,
        SUM(CASE WHEN status='FAILED' THEN 1 ELSE 0 END) AS failed
        FROM sync_queue WHERE branch_id=? AND is_deleted=0''',
      [branchId],
    );
    _pendingSyncCount = (pending.first['pending'] as num? ?? 0).toInt();
    _failedSyncCount = (pending.first['failed'] as num? ?? 0).toInt();
    notifyListeners();
  }

  /// Completes a sale locally and schedules an optional network sync.
  Future<SaleInvoiceModel> completeSale({
    required String branchId,
    required String cashierUserId,
    required List<PosCartItemModel> items,
    required String priceTier,
    required List<SalePaymentInput> payments,
    String? customerPartyId,
    double discountAmount = 0,
    double discountPct = 0,
    double roundingDiff = 0,
  }) async {
    _setBusy(true);
    try {
      final result = await _engine.completeSale(
        branchId: branchId,
        cashierUserId: cashierUserId,
        items: items,
        priceTier: priceTier,
        payments: payments,
        customerPartyId: customerPartyId,
        discountAmount: discountAmount,
        discountPct: discountPct,
        roundingDiff: roundingDiff,
      );
      await refresh(branchId);
      _lastError = null;
      return result;
    } catch (error) {
      _lastError = error.toString();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  /// Saves a receipt or payment voucher locally.
  Future<String> postVoucher({
    required String branchId,
    required String partyId,
    required String cashAccountId,
    required String voucherType,
    required String method,
    required double amount,
    String? walletRefNo,
    String description = '',
  }) async {
    _setBusy(true);
    try {
      final id = await _engine.saveVoucher(
        branchId: branchId,
        partyId: partyId,
        cashAccountId: cashAccountId,
        voucherType: voucherType,
        method: method,
        amount: amount,
        walletRefNo: walletRefNo,
        description: description,
      );
      await refresh(branchId);
      _lastError = null;
      return id;
    } catch (error) {
      _lastError = error.toString();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  /// Attempts to send the next queued batch if an API client was configured.
  Future<void> syncNow(String branchId) async {
    _syncState = 'SYNCING';
    _setBusy(true);
    try {
      final result = await _engine.syncPendingBatch(branchId);
      _syncState = result == null
          ? 'LOCAL_ONLY'
          : result.rejected.isEmpty
              ? 'SYNCED'
              : 'PARTIAL';
      await refresh(branchId);
      _lastError = null;
    } catch (error) {
      _syncState = 'FAILED';
      _lastError = error.toString();
      await refresh(branchId);
    } finally {
      _setBusy(false);
      notifyListeners();
    }
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }
}
