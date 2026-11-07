import 'dart:math';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';
import '../models/erp_and_sync_models.dart';
import '../models/product_and_unit_models.dart';

/// Decodes configurable EAN-13 scale labels and looks up ordinary unit barcodes.
class ScaleAndBarcodeParser {
  const ScaleAndBarcodeParser({
    this.scalePrefixes = const ['20', '21'],
    this.pluStart = 2,
    this.pluLength = 4,
    this.quantityStart = 6,
    this.quantityLength = 5,
    this.quantityDivisor = 1000,
    this.quantityUnit = 'كيلو',
  });

  final List<String> scalePrefixes;
  final int pluStart, pluLength, quantityStart, quantityLength;
  final double quantityDivisor;
  final String quantityUnit;

  /// Returns scale data only when both the layout and EAN-13 check digit are valid.
  ScaleBarcodeResult? parseScaleBarcode(String raw) {
    final code = raw.trim();
    if (!isValidEan13(code) || !scalePrefixes.any(code.startsWith)) return null;
    final pluEnd = pluStart + pluLength;
    final qtyEnd = quantityStart + quantityLength;
    if (pluStart < 0 || quantityStart < 0 || pluEnd > 12 ||
        qtyEnd > 12 || quantityDivisor <= 0) return null;
    final qty = int.tryParse(code.substring(quantityStart, qtyEnd));
    if (qty == null || qty <= 0) return null;
    return ScaleBarcodeResult(
      pluCode: code.substring(pluStart, pluEnd),
      quantity: qty / quantityDivisor,
      quantityUnit: quantityUnit,
      rawBarcode: code,
    );
  }

  /// Validates a 13-digit EAN barcode using its standard alternating weights.
  bool isValidEan13(String value) {
    if (!RegExp(r'^\d{13}$').hasMatch(value)) return false;
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      sum += int.parse(value[i]) * (i.isOdd ? 3 : 1);
    }
    return (10 - sum % 10) % 10 == int.parse(value[12]);
  }

  /// Resolves a scale PLU or a normal unit barcode against the local catalogue.
  Future<BarcodeLookupResult?> lookup(String raw, {Database? database}) async {
    final db = database ?? await DatabaseHelper.instance.database;
    final scale = parseScaleBarcode(raw);
    final rows = scale == null
        ? await db.rawQuery(
            '''SELECT p.*, u.id AS unit_id, u.unit_name, u.conversion_factor,
                      u.barcode, u.cost_price, u.retail_price, u.wholesale_price,
                      u.min_sell_price, u.is_default_pos_unit
               FROM product_units_barcodes u JOIN products p ON p.id=u.product_id
               WHERE u.barcode=? AND p.is_active=1 AND p.is_deleted=0
                 AND u.is_deleted=0 LIMIT 1''', [raw.trim()])
        : await db.rawQuery(
            '''SELECT p.*, u.id AS unit_id, u.unit_name, u.conversion_factor,
                      u.barcode, u.cost_price, u.retail_price, u.wholesale_price,
                      u.min_sell_price, u.is_default_pos_unit
               FROM products p JOIN product_units_barcodes u ON u.product_id=p.id
               WHERE p.scale_plu_code=? AND p.product_type='WEIGHTED_SCALE'
                 AND p.is_active=1 AND p.is_deleted=0 AND u.is_deleted=0
               ORDER BY u.is_default_pos_unit DESC LIMIT 1''', [scale.pluCode]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final product = ProductModel.fromMap(row);
    final unit = ProductUnitBarcodeModel(
      id: row['unit_id'] as String,
      productId: product.id,
      unitName: row['unit_name'] as String,
      conversionFactor: (row['conversion_factor'] as num).toDouble(),
      barcode: row['barcode'] as String?,
      costPrice: (row['cost_price'] as num).toDouble(),
      retailPrice: (row['retail_price'] as num).toDouble(),
      wholesalePrice: (row['wholesale_price'] as num).toDouble(),
      minSellPrice: (row['min_sell_price'] as num).toDouble(),
      isDefaultPosUnit: (row['is_default_pos_unit'] as num? ?? 0) == 1,
    );
    return BarcodeLookupResult(product: product, unit: unit, scaleResult: scale);
  }
}

/// A resolved product and its sellable unit, optionally with scale quantity data.
class BarcodeLookupResult {
  const BarcodeLookupResult({required this.product, required this.unit, this.scaleResult});
  final ProductModel product;
  final ProductUnitBarcodeModel unit;
  final ScaleBarcodeResult? scaleResult;
}

/// Describes one payment allocation submitted by the cashier.
class SalePaymentInput {
  const SalePaymentInput({
    required this.method, required this.amount,
    this.cashAccountId, this.walletRefNo,
  });
  final String method;
  final double amount;
  final String? cashAccountId;
  final String? walletRefNo;
}

/// Posts sales and their stock, accounting, party and sync effects atomically.
class PostingAndSalesService {
  PostingAndSalesService({DatabaseHelper? databaseHelper})
      : _helper = databaseHelper ?? DatabaseHelper.instance;
  final DatabaseHelper _helper;

  /// Commits the complete sale in one SQLite transaction or rolls back every effect.
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
    if (items.isEmpty) throw ArgumentError('لا يمكن حفظ فاتورة بلا أصناف');
    if (!['RETAIL', 'WHOLESALE'].contains(priceTier)) throw ArgumentError('فئة السعر غير صحيحة');
    for (final item in items) {
      if (item.quantity <= 0 || item.conversionFactor <= 0 || item.unitPrice < 0 ||
          item.lineDiscountAmount < 0) throw ArgumentError('بيانات أحد الأصناف غير صحيحة');
    }
    for (final payment in payments) {
      if (payment.amount <= 0) throw ArgumentError('قيمة الدفعة يجب أن تكون موجبة');
      if (payment.method == 'WALLET' &&
          (payment.walletRefNo == null || payment.walletRefNo!.trim().isEmpty)) {
        throw ArgumentError('رقم إشعار المحفظة مطلوب');
      }
    }

    final db = await _helper.database;
    return db.transaction((txn) async {
      final now = DateTime.now().toIso8601String();
      final invoiceId = _id('inv');
      final subtotal = items.fold<double>(0, (s, i) => s + i.quantity * i.unitPrice);
      final itemDiscounts = items.fold<double>(0, (s, i) => s + i.lineDiscountAmount);
      final net = subtotal - itemDiscounts - discountAmount + roundingDiff;
      if (net < 0) throw ArgumentError('إجمالي الفاتورة غير صالح');
      final paymentTotal = payments.fold<double>(0, (s, p) => s + p.amount);
      final paid = min(paymentTotal, net).toDouble();
      final change = max(0, paymentTotal - net).toDouble();
      final remaining = max(0, net - paymentTotal).toDouble();
      if (remaining > 0 && customerPartyId == null) {
        throw ArgumentError('حدد العميل لتسجيل المبلغ المتبقي عليه');
      }
      if (customerPartyId != null) {
        final parties = await txn.query('parties',
          where: 'id=? AND is_deleted=0', whereArgs: [customerPartyId], limit: 1);
        if (parties.isEmpty) throw StateError('العميل غير موجود');
        if ((parties.first['is_blocked'] as num? ?? 0) == 1 && remaining > 0) {
          throw StateError('العميل موقوف عن الشراء الآجل');
        }
        final balances = await txn.rawQuery(
          'SELECT net FROM v_party_balance WHERE party_id=?', [customerPartyId]);
        final balance = balances.isEmpty ? 0.0 : (balances.first['net'] as num).toDouble();
        final limitValue = (parties.first['credit_limit'] as num? ?? 0).toDouble();
        if (remaining > 0 && limitValue > 0 && balance + remaining > limitValue) {
          throw StateError('تم تجاوز الحد الائتماني للعميل');
        }
      }

      final invoiceNo = await _nextNumber(txn, branchId, 'SALE', now);
      final saleType = remaining > 0 && paid > 0 ? 'MIXED' : remaining > 0 ? 'CREDIT' : 'CASH';
      final totalCost = items.fold<double>(0, (s, i) => s + i.baseQuantity * i.unitCost);
      final paymentAllocations = <Map<String, Object?>>[];
      var allocationRemaining = paid;
      for (final payment in payments) {
        final amount = min(payment.amount, allocationRemaining).toDouble();
        if (amount <= 0) continue;
        allocationRemaining -= amount;
        var glAccountId = 'gl-cash';
        if (payment.cashAccountId != null) {
          final accountRows = await txn.query('cash_accounts',
            columns: ['gl_account_id'],
            where: 'id=? AND is_deleted=0',
            whereArgs: [payment.cashAccountId], limit: 1);
          if (accountRows.isEmpty) throw StateError('حساب الدفع غير موجود');
          glAccountId = accountRows.first['gl_account_id'] as String? ?? 'gl-cash';
        }
        paymentAllocations.add({
          'input': payment, 'amount': amount, 'glAccountId': glAccountId,
        });
      }
      if (allocationRemaining > 0.01) {
        throw StateError('مجموع الدفعات أقل من المبلغ المسدد المحدد');
      }
      await txn.insert('sales_invoices', {
        ..._base(invoiceId, branchId, now),
        'invoice_no': invoiceNo, 'invoice_date': now,
        'cashier_user_id': cashierUserId, 'customer_party_id': customerPartyId,
        'price_tier': priceTier, 'sale_type': saleType, 'status': 'COMPLETED',
        'hold_label': null, 'subtotal': subtotal, 'discount_pct': discountPct,
        'discount_amount': itemDiscounts + discountAmount, 'rounding_diff': roundingDiff,
        'net_total': net, 'paid_total': paid, 'change_returned': change,
        'remaining_alayh': remaining, 'total_cost': totalCost, 'journal_entry_id': null,
      });

      for (final item in items) {
        final baseQty = item.baseQuantity;
        final stockRows = await txn.query('products',
          columns: ['stock_base_qty'],
          where: 'id=? AND is_active=1 AND is_deleted=0',
          whereArgs: [item.productId], limit: 1);
        if (stockRows.isEmpty) throw StateError('الصنف غير موجود أو غير نشط');
        final stock = (stockRows.first['stock_base_qty'] as num).toDouble();
        if (stock + 1e-7 < baseQty) throw StateError('المخزون غير كافٍ للصنف: ${item.productName}');
        await txn.update('products', {
          'stock_base_qty': stock - baseQty, 'updated_at': now,
        }, where: 'id=?', whereArgs: [item.productId]);
        final lineId = _id('line');
        await txn.insert('sales_invoice_items', {
          ..._base(lineId, branchId, now), 'invoice_id': invoiceId,
          'product_id': item.productId, 'unit_barcode_id': item.unitId,
          'unit_name': item.unitName, 'conversion_factor': item.conversionFactor,
          'qty_sold': item.quantity, 'base_qty_deducted': baseQty,
          'unit_price': item.unitPrice, 'line_discount_amount': item.lineDiscountAmount,
          'line_total': item.lineTotal, 'line_cost': baseQty * item.unitCost,
        });
        final movementId = _id('stock');
        await txn.insert('stock_movements', {
          ..._base(movementId, branchId, now), 'product_id': item.productId,
          'movement_date': now, 'movement_type': 'SALE_OUT',
          'quantity_base': -baseQty, 'unit_cost_base': item.unitCost,
          'doc_type': 'SALE', 'doc_id': invoiceId,
        });
      }

      final journalId = _id('je');
      final journalNo = await _nextNumber(txn, branchId, 'JOURNAL', now);
      await txn.insert('journal_entries', {
        ..._base(journalId, branchId, now), 'entry_no': journalNo,
        'entry_date': now, 'doc_type': 'SALE', 'doc_id': invoiceId,
        'description': 'ترحيل فاتورة بيع $invoiceNo',
      });
      for (final allocation in paymentAllocations) {
        await _journalLine(
          txn, branchId, journalId,
          allocation['glAccountId'] as String,
          allocation['amount'] as double, 0, now,
        );
      }
      if (remaining > 0) {
        await _journalLine(txn, branchId, journalId, 'gl-receivable', remaining, 0, now);
      }
      if (net > 0) await _journalLine(txn, branchId, journalId, 'gl-sales', 0, net, now);
      if (totalCost > 0) {
        await _journalLine(txn, branchId, journalId, 'gl-cogs', totalCost, 0, now);
        await _journalLine(txn, branchId, journalId, 'gl-inventory', 0, totalCost, now);
      }
      final journalTotals = await txn.rawQuery(
        'SELECT SUM(dr_amount) AS dr, SUM(cr_amount) AS cr FROM journal_lines WHERE journal_entry_id=?',
        [journalId]);
      final dr = (journalTotals.first['dr'] as num? ?? 0).toDouble();
      final cr = (journalTotals.first['cr'] as num? ?? 0).toDouble();
      if ((dr - cr).abs() > 0.01) throw StateError('القيد المحاسبي غير متوازن');

      if (customerPartyId != null) {
        if (net > 0) await _ledgerLine(txn, branchId, customerPartyId, journalId,
          invoiceId, 'SALE', net, 0, 'فاتورة بيع $invoiceNo', now);
        if (paid > 0) await _ledgerLine(txn, branchId, customerPartyId, journalId,
          invoiceId, 'SALE_PAYMENT', 0, paid, 'سداد فاتورة $invoiceNo', now);
      }

      for (final allocation in paymentAllocations) {
        final payment = allocation['input'] as SalePaymentInput;
        final amount = allocation['amount'] as double;
        final paymentId = _id('pay');
        await txn.insert('sales_payments', {
          ..._base(paymentId, branchId, now), 'invoice_id': invoiceId,
          'cash_account_id': payment.cashAccountId, 'method': payment.method,
          'amount': amount, 'wallet_ref_no': payment.walletRefNo,
        });
        if (payment.cashAccountId != null) {
          await txn.rawUpdate(
            'UPDATE cash_accounts SET current_balance=current_balance+?, updated_at=? WHERE id=?',
            [amount, now, payment.cashAccountId]);
        }
      }
      await txn.update('sales_invoices', {'journal_entry_id': journalId},
        where: 'id=?', whereArgs: [invoiceId]);
      final invoicePayload = (await txn.query('sales_invoices',
        where: 'id=?', whereArgs: [invoiceId], limit: 1)).first;
      final itemPayload = await txn.query('sales_invoice_items',
        where: 'invoice_id=?', whereArgs: [invoiceId]);
      final paymentPayload = await txn.query('sales_payments',
        where: 'invoice_id=?', whereArgs: [invoiceId]);
      final journalPayload = await txn.query('journal_lines',
        where: 'journal_entry_id=?', whereArgs: [journalId]);
      final ledgerPayload = customerPartyId == null
          ? <Map<String, Object?>>[]
          : await txn.query('lah_alayh_ledger',
              where: 'doc_id=?', whereArgs: [invoiceId]);
      final queueId = _id('sync');
      await txn.insert('sync_queue', {
        'id': queueId, 'uuid': 'uuid-$queueId', 'branch_id': branchId,
        'table_name': 'sales_invoices', 'row_uuid': invoiceId, 'operation': 'INSERT',
        'payload_json': jsonEncode({
          'invoice': invoicePayload,
          'items': itemPayload,
          'payments': paymentPayload,
          'journalLines': journalPayload,
          'partyLedger': ledgerPayload,
        }),
        'sync_version': 1, 'batch_id': null, 'status': 'PENDING',
        'queued_at': now, 'created_at': now, 'updated_at': now, 'is_deleted': 0,
      });
      return SaleInvoiceModel(
        id: invoiceId, invoiceNo: invoiceNo, netTotal: net,
        paidTotal: paid, changeReturned: change, remainingAlayh: remaining,
      );
    });
  }

  Future<void> _journalLine(Transaction txn, String branch, String journal,
      String account, double dr, double cr, String now) async {
    if (dr == 0 && cr == 0) return;
    final id = _id('jl');
    await txn.insert('journal_lines', {
      ..._base(id, branch, now), 'journal_entry_id': journal,
      'gl_account_id': account, 'dr_amount': dr, 'cr_amount': cr,
    });
  }

  Future<void> _ledgerLine(Transaction txn, String branch, String party,
      String journal, String invoice, String type, double alayh, double lah,
      String text, String now) async {
    final id = _id('ledger');
    await txn.insert('lah_alayh_ledger', {
      ..._base(id, branch, now), 'party_id': party, 'entry_date': now,
      'entry_type': type, 'alayh_amount': alayh, 'lah_amount': lah,
      'doc_type': 'SALE', 'doc_id': invoice, 'statement_ar': text,
      'journal_entry_id': journal,
    });
  }

  Future<String> _nextNumber(Transaction txn, String branch, String type, String now) async {
    final year = DateTime.now().year;
    final rows = await txn.query('number_sequences',
      where: 'branch_id=? AND doc_type=? AND year=?',
      whereArgs: [branch, type, year], limit: 1);
    if (rows.isEmpty) {
      final id = _id('seq');
      final prefix = type == 'SALE' ? 'S' : 'J';
      await txn.insert('number_sequences', {
        ..._base(id, branch, now), 'doc_type': type, 'prefix': prefix,
        'year': year, 'last_no': 1, 'pad_length': 6,
      });
      return '$prefix$year-000001';
    }
    final row = rows.first;
    final next = (row['last_no'] as num).toInt() + 1;
    await txn.update('number_sequences', {'last_no': next, 'updated_at': now},
      where: 'id=?', whereArgs: [row['id']]);
    return '${row['prefix']}$year-${next.toString().padLeft((row['pad_length'] as num).toInt(), '0')}';
  }

  Map<String, Object?> _base(String id, String branch, String now) => {
    'id': id, 'uuid': 'uuid-$id', 'branch_id': branch,
    'created_at': now, 'updated_at': now, 'is_deleted': 0,
    'sync_status': 'LOCAL', 'sync_version': 1,
  };

  String _id(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}';
}