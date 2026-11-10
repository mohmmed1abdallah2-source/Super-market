import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:api_client/api_client.dart';
import 'package:core_contracts/core_contracts.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/database_helper.dart';
import '../models/erp_and_sync_models.dart';
import '../services/scale_and_pos_service.dart';

/// Facade for the existing configurable scale and ordinary barcode parser.
class ScalePosAndLedgerService {
  /// Creates the parser facade.
  ScalePosAndLedgerService({ScaleAndBarcodeParser? parser})
      : _parser = parser ?? const ScaleAndBarcodeParser();

  final ScaleAndBarcodeParser _parser;

  /// Parses a scale label without touching the database.
  ScaleBarcodeResult? parseScaleBarcode(String barcode) =>
      _parser.parseScaleBarcode(barcode);

  /// Resolves a scanned barcode to its local product and unit.
  Future<BarcodeLookupResult?> lookupBarcode(
    String barcode, {
    Database? database,
  }) =>
      _parser.lookup(barcode, database: database);
}

/// Executes local POS and ledger transactions and synchronizes queued events.
///
/// SQLite remains the immediate operational store. Network synchronization is
/// optional and always happens after the local transaction has committed.
class LocalPosAndLedgerEngine {
  /// Creates the local engine.
  LocalPosAndLedgerEngine({
    DatabaseHelper? databaseHelper,
    ApiClient? apiClient,
    ScaleAndBarcodeParser? parser,
  })  : _helper = databaseHelper ?? DatabaseHelper.instance,
        _apiClient = apiClient,
        _parser = parser ?? const ScaleAndBarcodeParser();

  final DatabaseHelper _helper;
  ApiClient? _apiClient;
  final ScaleAndBarcodeParser _parser;
  static const Uuid _uuid = Uuid();

  /// Attaches an authenticated API client after the user session is established.
  void configureApiClient(ApiClient client) {
    _apiClient = client;
  }

  /// Resolves a barcode locally without requiring an API connection.
  Future<BarcodeLookupResult?> lookupBarcode(String barcode) =>
      _parser.lookup(barcode);

  /// Commits a sale locally and schedules a best-effort background sync.
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
    final result = await PostingAndSalesService(databaseHelper: _helper).completeSale(
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
    unawaited(_syncAfterCommit(branchId));
    return result;
  }

  /// Creates a customer or supplier locally and queues the new party for sync.
  Future<String> createParty({
    required String branchId,
    required String partyType,
    required String code,
    required String name,
    String? phone,
    String? address,
    double creditLimit = 0,
    int paymentTermsDays = 0,
    String priceTier = 'RETAIL',
  }) async {
    final type = partyType.toUpperCase();
    if (!const {'CUSTOMER', 'SUPPLIER'}.contains(type)) {
      throw ArgumentError.value(partyType, 'partyType');
    }
    if (code.trim().isEmpty || name.trim().isEmpty) {
      throw ArgumentError('كود الطرف واسمه مطلوبان');
    }
    if (creditLimit < 0 || paymentTermsDays < 0) {
      throw ArgumentError('الحد الائتماني ومدة السداد لا يمكن أن يكونا سالبين');
    }
    final db = await _helper.database;
    final id = _localId('party');
    final queueId = _localId('sync');
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final existing = await txn.query(
        'parties',
        where: 'branch_id=? AND code=? AND is_deleted=0',
        whereArgs: [branchId, code.trim()],
        limit: 1,
      );
      if (existing.isNotEmpty) throw StateError('كود الطرف مسجل مسبقاً');
      final party = <String, Object?>{
        ..._base(id, branchId, now),
        'party_type': type,
        'code': code.trim(),
        'name_ar': name.trim(),
        'phone': phone?.trim(),
        'address': address?.trim(),
        'credit_limit': creditLimit,
        'payment_terms_days': paymentTermsDays,
        'price_tier': priceTier,
        'is_blocked': 0,
        'opening_alayh': 0,
        'opening_lah': 0,
      };
      await txn.insert('parties', party);
      await txn.insert('sync_queue', {
        'id': queueId,
        'uuid': 'uuid-$queueId',
        'branch_id': branchId,
        'table_name': 'parties',
        'row_uuid': id,
        'operation': 'INSERT',
        'payload_json': jsonEncode({'party': party}),
        'sync_version': 1,
        'batch_id': null,
        'status': 'PENDING',
        'queued_at': now,
        'created_at': now,
        'updated_at': now,
        'is_deleted': 0,
      });
    });
    unawaited(_syncAfterCommit(branchId));
    return id;
  }

  /// Saves a customer receipt or supplier payment atomically in SQLite.
  ///
  /// Receipt movements increase the selected customer's lah total. Payment
  /// movements increase the selected supplier's alayh total.
  Future<String> saveVoucher({
    required String branchId,
    required String partyId,
    required String cashAccountId,
    required String voucherType,
    required String method,
    required double amount,
    String? walletRefNo,
    String description = '',
  }) async {
    final normalizedType = voucherType.toUpperCase();
    final normalizedMethod = method.toUpperCase();
    if (!const {'RECEIPT', 'PAYMENT'}.contains(normalizedType)) {
      throw ArgumentError.value(voucherType, 'voucherType');
    }
    if (!const {'CASH', 'WALLET'}.contains(normalizedMethod)) {
      throw ArgumentError.value(method, 'method');
    }
    if (amount <= 0 || !amount.isFinite) {
      throw ArgumentError.value(amount, 'amount', 'Must be a positive amount.');
    }
    if (normalizedMethod == 'WALLET' &&
        (walletRefNo == null || walletRefNo.trim().length < 6)) {
      throw ArgumentError('رقم إشعار المحفظة يجب ألا يقل عن 6 خانات');
    }

    final db = await _helper.database;
    final voucherId = _localId('voucher');
    final journalId = _localId('journal');
    final ledgerId = _localId('ledger');
    final queueId = _localId('sync');
    final now = DateTime.now().toIso8601String();
    final voucherNo = 'V-${DateTime.now().millisecondsSinceEpoch}';

    await db.transaction((txn) async {
      final parties = await txn.query(
        'parties',
        where: 'id=? AND branch_id=? AND is_deleted=0',
        whereArgs: [partyId, branchId],
        limit: 1,
      );
      if (parties.isEmpty) throw StateError('الطرف غير موجود في هذا الفرع');
      final expectedType = normalizedType == 'RECEIPT' ? 'CUSTOMER' : 'SUPPLIER';
      if (parties.first['party_type'] != expectedType) {
        throw StateError('نوع السند لا يتوافق مع نوع الطرف');
      }

      final accounts = await txn.query(
        'cash_accounts',
        where: 'id=? AND branch_id=? AND is_deleted=0',
        whereArgs: [cashAccountId, branchId],
        limit: 1,
      );
      if (accounts.isEmpty) throw StateError('الصندوق أو المحفظة غير موجودة');
      final account = accounts.first;
      final accountKind = account['account_kind'] as String;
      if (normalizedMethod == 'WALLET' && accountKind != 'WALLET') {
        throw StateError('اختر حساب محفظة إلكترونية');
      }
      if (normalizedMethod == 'CASH' && accountKind == 'WALLET') {
        throw StateError('اختر صندوقاً نقدياً لطريقة الدفع النقدي');
      }
      final balance = (account['current_balance'] as num).toDouble();
      final isReceipt = normalizedType == 'RECEIPT';
      if (!isReceipt && balance < amount) {
        throw StateError('الرصيد المتاح في الصندوق أو المحفظة غير كافٍ');
      }

      final cashGl = account['gl_account_id'] as String? ?? 'gl-cash';
      final counterGl = isReceipt ? 'gl-receivable' : 'gl-payable';
      final counterAccounts = await txn.query(
        'chart_of_accounts',
        where: 'id=? AND branch_id=? AND is_deleted=0',
        whereArgs: [counterGl, branchId],
        limit: 1,
      );
      if (counterAccounts.isEmpty) throw StateError('دليل الحسابات غير مكتمل');

      await txn.insert('vouchers', {
        ..._base(voucherId, branchId, now),
        'voucher_no': voucherNo,
        'voucher_type': normalizedType,
        'voucher_date': now,
        'party_id': partyId,
        'cash_account_id': cashAccountId,
        'amount': amount,
        'method': normalizedMethod,
        'wallet_ref_no': normalizedMethod == 'WALLET' ? walletRefNo!.trim() : null,
        'description': description,
        'journal_entry_id': journalId,
      });

      await txn.insert('journal_entries', {
        ..._base(journalId, branchId, now),
        'entry_no': voucherNo,
        'entry_date': now,
        'doc_type': 'VOUCHER',
        'doc_id': voucherId,
        'description': description,
      });
      await _insertJournalLine(
        txn,
        branchId: branchId,
        journalId: journalId,
        accountId: cashGl,
        dr: isReceipt ? amount : 0,
        cr: isReceipt ? 0 : amount,
        now: now,
      );
      await _insertJournalLine(
        txn,
        branchId: branchId,
        journalId: journalId,
        accountId: counterGl,
        dr: isReceipt ? 0 : amount,
        cr: isReceipt ? amount : 0,
        now: now,
      );

      await txn.rawUpdate(
        'UPDATE cash_accounts SET current_balance=current_balance+?, updated_at=?, sync_version=sync_version+1 WHERE id=?',
        [isReceipt ? amount : -amount, now, cashAccountId],
      );
      await txn.insert('lah_alayh_ledger', {
        ..._base(ledgerId, branchId, now),
        'party_id': partyId,
        'entry_date': now,
        'entry_type': normalizedType,
        'alayh_amount': isReceipt ? 0 : amount,
        'lah_amount': isReceipt ? amount : 0,
        'doc_type': 'VOUCHER',
        'doc_id': voucherId,
        'statement_ar': description.isEmpty ? voucherNo : description,
        'journal_entry_id': journalId,
      });

      await txn.insert('sync_queue', {
        'id': queueId,
        'uuid': 'uuid-$queueId',
        'branch_id': branchId,
        'table_name': 'vouchers',
        'row_uuid': voucherId,
        'operation': 'INSERT',
        'payload_json': jsonEncode({
          'voucher': {
            'id': voucherId,
            'voucher_no': voucherNo,
            'voucher_type': normalizedType,
            'party_id': partyId,
            'cash_account_id': cashAccountId,
            'amount': amount,
            'method': normalizedMethod,
            'wallet_ref_no': normalizedMethod == 'WALLET' ? walletRefNo!.trim() : null,
            'description': description,
          },
        }),
        'sync_version': 1,
        'batch_id': null,
        'status': 'PENDING',
        'queued_at': now,
        'created_at': now,
        'updated_at': now,
        'is_deleted': 0,
      });
    });

    unawaited(_syncAfterCommit(branchId));
    return voucherId;
  }

  /// Sends at most 100 pending local events through the idempotent batch API.
  Future<SyncBatchResponseDto?> syncPendingBatch(
    String branchId, {
    int maxEvents = 100,
  }) async {
    final client = _apiClient;
    if (client == null) return null;
    final db = await _helper.database;
    final rows = await db.query(
      'sync_queue',
      where: 'branch_id=? AND status IN (?, ?)',
      whereArgs: [branchId, 'PENDING', 'FAILED'],
      orderBy: 'queued_at ASC',
      limit: maxEvents.clamp(1, 100).toInt(),
    );
    if (rows.isEmpty) return null;

    final operations = <SyncOperationDto>[];
    final queueByOperation = <String, String>{};
    for (final row in rows) {
      final rawPayload = jsonDecode(row['payload_json'] as String);
      if (rawPayload is! Map<String, dynamic>) {
        throw FormatException('Invalid queued payload for ${row['id']}');
      }
      final operationId = _stableUuid(row['uuid'] as String);
      final table = row['table_name'] as String;
      late final String operationType;
      late final Map<String, dynamic> payload;
      if (table == 'sales_invoices') {
        operationType = 'SALE_INVOICE';
        payload = await _mapSalePayload(db, rawPayload, operationId);
      } else if (table == 'vouchers') {
        operationType = 'VOUCHER';
        payload = _mapVoucherPayload(rawPayload, operationId);
      } else if (table == 'parties') {
        operationType = 'PARTY_CREATE';
        payload = _mapPartyPayload(rawPayload);
      } else {
        throw StateError('Unsupported sync queue table: $table');
      }
      operations.add(SyncOperationDto(
        operationId: operationId,
        operationType: operationType,
        payload: payload,
      ));
      queueByOperation[operationId] = row['id'] as String;
    }

    final batchId = _stableUuid(rows.map((row) => row['uuid']).join('|'));
    final request = SyncBatchRequestDto(batchId: batchId, operations: operations);
    final result = await client.postSyncBatch(
      request: request,
      idempotencyKey: 'sync-$batchId',
    );
    final accepted = result.acceptedIds.toSet();
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      for (final entry in queueByOperation.entries) {
        await txn.update(
          'sync_queue',
          {
            'status': accepted.contains(entry.key) ? 'BATCHED_SENT' : 'FAILED',
            'batch_id': batchId,
            'updated_at': now,
          },
          where: 'id=?',
          whereArgs: [entry.value],
        );
      }
    });
    return result;
  }

  Future<Map<String, dynamic>> _mapSalePayload(
    Database db,
    Map<String, dynamic> source,
    String operationId,
  ) async {
    final invoice = Map<String, dynamic>.from(source['invoice'] as Map);
    final rawItems = (source['items'] as List<dynamic>? ?? const []);
    final rawPayments = (source['payments'] as List<dynamic>? ?? const []);
    final items = rawItems.map((raw) {
      final row = Map<String, dynamic>.from(raw as Map);
      return <String, dynamic>{
        'id': _stableUuid(row['uuid']?.toString() ?? row['id'].toString()),
        'productId': row['product_id'],
        'barcode': null,
        'unitName': row['unit_name'],
        'qtySold': row['qty_sold'],
        'conversionFactor': row['conversion_factor'],
        'unitPrice': row['unit_price'],
        'lineTotal': row['line_total'],
      };
    }).toList();

    final payments = <Map<String, dynamic>>[];
    for (final raw in rawPayments) {
      final row = Map<String, dynamic>.from(raw as Map);
      final cashId = row['cash_account_id'] as String?;
      String? provider;
      if (cashId != null && row['method'] == 'WALLET') {
        final accountRows = await db.query(
          'cash_accounts',
          columns: ['wallet_provider'],
          where: 'id=?',
          whereArgs: [cashId],
          limit: 1,
        );
        if (accountRows.isNotEmpty) {
          provider = _normalizeWallet(accountRows.first['wallet_provider']?.toString());
        }
      }
      payments.add({
        'id': _stableUuid(row['uuid']?.toString() ?? row['id'].toString()),
        'method': row['method'],
        'amount': row['amount'],
        'cashAccountId': cashId,
        'walletProvider': provider,
        'walletRefNo': row['wallet_ref_no'],
      });
    }

    final remainingAlayh = (invoice['remaining_alayh'] as num? ?? 0).toDouble();
    if (remainingAlayh > 0) {
      payments.add({
        'id': _stableUuid('credit-payment:' + operationId),
        'method': 'CREDIT',
        'amount': remainingAlayh,
        'cashAccountId': null,
        'walletProvider': null,
        'walletRefNo': null,
      });
    }

    return {
      'operationId': operationId,
      'customerPartyId': invoice['customer_party_id'],
      'priceTier': invoice['price_tier'],
      'items': items,
      'payments': payments,
      'discountAmount': invoice['discount_amount'] ?? 0,
      'changeReturned': invoice['change_returned'] ?? 0,
    };
  }

  Map<String, dynamic> _mapVoucherPayload(
    Map<String, dynamic> source,
    String operationId,
  ) {
    final voucher = Map<String, dynamic>.from(source['voucher'] as Map);
    return {
      'operationId': operationId,
      'voucherType': voucher['voucher_type'],
      'partyId': voucher['party_id'],
      'cashAccountId': voucher['cash_account_id'],
      'amount': voucher['amount'],
      'method': voucher['method'],
      'walletRefNo': voucher['wallet_ref_no'],
      'description': voucher['description'],
    };
  }

  Map<String, dynamic> _mapPartyPayload(Map<String, dynamic> source) {
    final party = source['party'] is Map
        ? Map<String, dynamic>.from(source['party'] as Map)
        : source;
    return {
      'id': party['id'],
      'partyType': party['party_type'] ?? party['partyType'],
      'code': party['code'],
      'name': party['name_ar'] ?? party['name'],
      'phone': party['phone'],
      'address': party['address'],
      'creditLimit': party['credit_limit'] ?? 0,
      'paymentTermsDays': party['payment_terms_days'] ?? 0,
      'priceTier': party['price_tier'] ?? 'RETAIL',
    };
  }

  String? _normalizeWallet(String? value) {
    switch (value?.toUpperCase()) {
      case 'JAWALI':
        return 'JAWALI';
      case 'JAIB':
      case 'JEEB':
        return 'JEEB';
      case 'FLOUSK':
      case 'FLOOSAK':
        return 'FLOOSAK';
      case 'KURAIMI':
        return 'KURAIMI';
      default:
        return null;
    }
  }

  Future<void> _syncAfterCommit(String branchId) async {
    try {
      await syncPendingBatch(branchId);
    } catch (_) {
      // The local queue remains the source of retryable work when the API is offline.
    }
  }

  Future<void> _insertJournalLine(
    Transaction txn, {
    required String branchId,
    required String journalId,
    required String accountId,
    required double dr,
    required double cr,
    required String now,
  }) async {
    final id = _localId('jl');
    await txn.insert('journal_lines', {
      ..._base(id, branchId, now),
      'journal_entry_id': journalId,
      'gl_account_id': accountId,
      'dr_amount': dr,
      'cr_amount': cr,
    });
  }

  Map<String, Object?> _base(String id, String branchId, String now) => {
        'id': id,
        'uuid': 'uuid-$id',
        'branch_id': branchId,
        'created_at': now,
        'updated_at': now,
        'is_deleted': 0,
        'sync_status': 'LOCAL',
        'sync_version': 1,
      };

  String _localId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 20)}';

  String _stableUuid(String value) =>
      _uuid.v5(Uuid.NAMESPACE_URL, 'supermarket-erp:$value');
}
