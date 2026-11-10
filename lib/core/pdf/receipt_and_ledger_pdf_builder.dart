import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/erp_and_sync_models.dart';
import '../../providers/pos_and_ledger_provider.dart';
import 'official_report_template.dart';

/// Builds official party statements and financial summary PDFs.
class ReceiptAndLedgerPdfBuilder {
  ReceiptAndLedgerPdfBuilder._();

  /// Generates an official A4 statement for one customer or supplier.
  static Future<Uint8List> previewPartyStatement({
    required PartyModel party,
    required List<Map<String, Object?>> entries,
    required double totalAlayh,
    required double totalLah,
    String currency = 'ر.ي',
    bool printAfterGenerate = true,
  }) async {
    final ordered = entries.toList()
      ..sort((a, b) => (a['entry_date']?.toString() ?? '')
          .compareTo(b['entry_date']?.toString() ?? ''));
    var running = 0.0;
    final rows = <List<String>>[];
    var index = 0;
    for (final entry in ordered) {
      index++;
      final alayh = _number(entry['alayh_amount']);
      final lah = _number(entry['lah_amount']);
      running += alayh - lah;
      rows.add([
        index.toString(),
        _date(entry['entry_date']),
        entry['statement_ar']?.toString() ?? '',
        entry['doc_id']?.toString() ?? '',
        _money(alayh, currency),
        _money(lah, currency),
        _balanceLabel(running, currency),
      ]);
    }
    final net = totalAlayh - totalLah;
    return OfficialReportTemplate.preview(
      reportTitle: 'كشف حساب ' + party.nameAr,
      rightHeader1: 'Global Enterprise Supermarket',
      rightHeader2: party.partyType == 'SUPPLIER' ? 'كشف حساب مورد' : 'كشف حساب عميل',
      rightHeader3: 'رقم الطرف: ' + party.code,
      date: _date(DateTime.now()),
      refNumber: party.id,
      summaryBoxes: [
        StatBoxData(number: '1', title: 'إجمالي ما عليه', value: _money(totalAlayh, currency)),
        StatBoxData(number: '2', title: 'إجمالي ما له', value: _money(totalLah, currency)),
        StatBoxData(number: '3', title: 'الصافي المتبقي', value: _balanceLabel(net, currency), isLarge: true),
      ],
      columns: const ['م', 'التاريخ', 'البيان', 'المستند', 'عليه', 'له', 'المتبقي'],
      rows: rows,
      fileName: 'party_statement_' + party.code + '.pdf',
      printAfterGenerate: printAfterGenerate,
      preferredRowsPerPage: 24,
    );
  }

  /// Generates an official A4 report for all customers or all suppliers.
  static Future<Uint8List> previewPartyBalances({
    required List<PartyBalanceRecord> parties,
    required String partyType,
    String currency = 'ر.ي',
    bool printAfterGenerate = true,
  }) async {
    final filtered = parties.where((record) => record.party.partyType == partyType).toList()
      ..sort((a, b) => a.party.nameAr.compareTo(b.party.nameAr));
    final totalAlayh = filtered.fold<double>(0, (sum, item) => sum + item.totalAlayh);
    final totalLah = filtered.fold<double>(0, (sum, item) => sum + item.totalLah);
    final rows = <List<String>>[];
    for (var i = 0; i < filtered.length; i++) {
      final item = filtered[i];
      rows.add([
        (i + 1).toString(),
        item.party.code,
        item.party.nameAr,
        _money(item.totalAlayh, currency),
        _money(item.totalLah, currency),
        _balanceLabel(item.totalAlayh - item.totalLah, currency),
      ]);
    }
    final isSupplier = partyType == 'SUPPLIER';
    return OfficialReportTemplate.preview(
      reportTitle: isSupplier ? 'ملخص أرصدة الموردين' : 'ملخص أرصدة العملاء',
      rightHeader1: 'Global Enterprise Supermarket',
      rightHeader2: 'الإدارة المالية',
      rightHeader3: 'تقرير أرصدة الأطراف',
      date: _date(DateTime.now()),
      refNumber: 'PARTY-BALANCES',
      summaryBoxes: [
        StatBoxData(number: '1', title: 'إجمالي ما عليه', value: _money(totalAlayh, currency)),
        StatBoxData(number: '2', title: 'إجمالي ما له', value: _money(totalLah, currency)),
        StatBoxData(number: '3', title: 'الصافي المتبقي', value: _balanceLabel(totalAlayh - totalLah, currency), isLarge: true),
      ],
      columns: const ['م', 'الكود', 'اسم الطرف', 'عليه', 'له', 'المتبقي'],
      rows: rows,
      fileName: isSupplier ? 'supplier_balances.pdf' : 'customer_balances.pdf',
      printAfterGenerate: printAfterGenerate,
      preferredRowsPerPage: 25,
    );
  }

  /// Generates an official A4 daily sales summary grouped by payment method.
  static Future<Uint8List> previewDailySalesByPayment({
    required DateTime date,
    required Map<String, double> totalsByMethod,
    required double netSales,
    required int invoiceCount,
    String currency = 'ر.ي',
    bool printAfterGenerate = true,
  }) async {
    const methods = {
      'CASH': 'نقداً',
      'WALLET': 'محافظ إلكترونية',
      'CREDIT': 'آجل',
      'MIXED': 'دفع مختلط',
    };
    final rows = <List<String>>[];
    var index = 0;
    for (final entry in totalsByMethod.entries) {
      index++;
      rows.add([index.toString(), methods[entry.key] ?? entry.key, _money(entry.value, currency)]);
    }
    final totalPayments = totalsByMethod.values.fold<double>(0, (a, b) => a + b);
    return OfficialReportTemplate.preview(
      reportTitle: 'تقرير مبيعات اليوم حسب طريقة الدفع',
      rightHeader1: 'Global Enterprise Supermarket',
      rightHeader2: 'الإدارة المالية',
      rightHeader3: 'ملخص حركة المبيعات اليومية',
      date: _date(date),
      refNumber: 'DAILY-SALES',
      summaryBoxes: [
        StatBoxData(number: '1', title: 'صافي المبيعات', value: _money(netSales, currency)),
        StatBoxData(number: '2', title: 'عدد الفواتير', value: invoiceCount.toString()),
        StatBoxData(number: '3', title: 'إجمالي المقبوضات', value: _money(totalPayments, currency)),
      ],
      columns: const ['م', 'طريقة الدفع', 'الإجمالي'],
      rows: rows,
      fileName: 'daily_sales_by_payment.pdf',
      printAfterGenerate: printAfterGenerate,
      preferredRowsPerPage: 20,
    );
  }

  static double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '') ?? 0;

  static String _date(Object? value) {
    if (value == null) return '';
    final parsed = value is DateTime ? value : DateTime.tryParse(value.toString());
    if (parsed == null) return value.toString();
    return parsed.year.toString().padLeft(4, '0') + '-' +
        parsed.month.toString().padLeft(2, '0') + '-' +
        parsed.day.toString().padLeft(2, '0');
  }

  static String _money(double value, String currency) =>
      value.toStringAsFixed(2) + ' ' + currency;

  static String _balanceLabel(double net, String currency) {
    if (net > 0.000001) return 'عليه ' + _money(net, currency);
    if (net < -0.000001) return 'له ' + _money(net.abs(), currency);
    return 'مسدَّد (0.00)';
  }
}

/// One item printed on a thermal cashier receipt.
class ThermalReceiptItem {
  /// Creates a thermal receipt item.
  const ThermalReceiptItem({
    required this.name,
    required this.unitName,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });

  /// Product display name.
  final String name;

  /// Sold unit label.
  final String unitName;

  /// Sold quantity.
  final double quantity;

  /// Price per selected unit.
  final double unitPrice;

  /// Final line amount.
  final double lineTotal;
}

/// Creates 58mm and 80mm thermal receipts with a scannable invoice barcode.
class ThermalReceiptBuilder {
  ThermalReceiptBuilder._();

  /// Builds receipt PDF bytes at the selected paper width.
  static Future<Uint8List> build({
    required String storeName,
    required String invoiceNo,
    required DateTime invoiceDate,
    required List<ThermalReceiptItem> items,
    required double netTotal,
    required double paidTotal,
    required double changeReturned,
    required double remainingAlayh,
    double paperWidthMm = 80,
    String currency = 'ر.ي',
  }) async {
    if (paperWidthMm != 58 && paperWidthMm != 80) {
      throw ArgumentError.value(paperWidthMm, 'paperWidthMm', 'Only 58mm and 80mm are supported.');
    }
    final fontData = await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
    final boldData = await rootBundle.load('assets/fonts/NotoNaskhArabic-Bold.ttf');
    final font = pw.Font.ttf(fontData);
    final bold = pw.Font.ttf(boldData);
    final width = paperWidthMm * PdfPageFormat.mm;
    final pageHeight = (260 + items.length * 28) * PdfPageFormat.mm;
    final document = pw.Document();
    String money(double value) => value.toStringAsFixed(2) + ' ' + currency;

    document.addPage(pw.Page(
      pageFormat: PdfPageFormat(width, pageHeight, marginAll: 3 * PdfPageFormat.mm),
      theme: pw.ThemeData.withFont(base: font, bold: bold),
      textDirection: pw.TextDirection.rtl,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Center(child: pw.Text(storeName, style: pw.TextStyle(font: bold, fontSize: 16))),
          pw.SizedBox(height: 4),
          pw.Center(child: pw.Text('إيصال بيع', style: pw.TextStyle(font: bold, fontSize: 12))),
          pw.Divider(),
          pw.Text('رقم الفاتورة: ' + invoiceNo, style: pw.TextStyle(font: bold, fontSize: 10)),
          pw.Text('التاريخ: ' + invoiceDate.toLocal().toString().substring(0, 16), style: pw.TextStyle(font: font, fontSize: 9)),
          pw.Divider(),
          for (final item in items) ...[
            pw.Text(item.name, style: pw.TextStyle(font: bold, fontSize: 10)),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(child: pw.Text(
                  item.quantity.toStringAsFixed(3) + ' ' + item.unitName + ' × ' + money(item.unitPrice),
                  style: pw.TextStyle(font: font, fontSize: 8),
                )),
                pw.Text(money(item.lineTotal), style: pw.TextStyle(font: bold, fontSize: 8)),
              ],
            ),
            pw.SizedBox(height: 3),
          ],
          pw.Divider(),
          _receiptTotalRow('الإجمالي الصافي', money(netTotal), font, bold),
          _receiptTotalRow('المدفوع', money(paidTotal), font, font),
          if (changeReturned > 0)
            _receiptTotalRow('الباقي للزبون', money(changeReturned), font, bold),
          if (remainingAlayh > 0)
            _receiptTotalRow('المتبقي عليه', money(remainingAlayh), font, bold),
          pw.SizedBox(height: 12),
          pw.Center(child: pw.BarcodeWidget(
            barcode: pw.Barcode.code128(),
            data: invoiceNo,
            width: width * 0.72,
            height: 42,
            drawText: true,
            textStyle: pw.TextStyle(font: font, fontSize: 8),
          )),
          pw.SizedBox(height: 8),
          pw.Center(child: pw.Text('شكراً لزيارتكم', style: pw.TextStyle(font: bold, fontSize: 10))),
        ],
      ),
    ));
    return document.save();
  }

  /// Builds and opens the platform print dialog for the receipt.
  static Future<void> print({
    required String storeName,
    required String invoiceNo,
    required DateTime invoiceDate,
    required List<ThermalReceiptItem> items,
    required double netTotal,
    required double paidTotal,
    required double changeReturned,
    required double remainingAlayh,
    double paperWidthMm = 80,
    String currency = 'ر.ي',
  }) async {
    final bytes = await build(
      storeName: storeName,
      invoiceNo: invoiceNo,
      invoiceDate: invoiceDate,
      items: items,
      netTotal: netTotal,
      paidTotal: paidTotal,
      changeReturned: changeReturned,
      remainingAlayh: remainingAlayh,
      paperWidthMm: paperWidthMm,
      currency: currency,
    );
    await Printing.layoutPdf(
      name: 'receipt_' + invoiceNo + '.pdf',
      onLayout: (_) async => bytes,
      format: PdfPageFormat(paperWidthMm * PdfPageFormat.mm, 300 * PdfPageFormat.mm),
    );
  }

  static pw.Widget _receiptTotalRow(
    String label,
    String value,
    pw.Font font,
    pw.Font valueFont,
  ) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label, style: pw.TextStyle(font: font, fontSize: 9)),
            pw.Text(value, style: pw.TextStyle(font: valueFont, fontSize: 9)),
          ],
        ),
      );
}
