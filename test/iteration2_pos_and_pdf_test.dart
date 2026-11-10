import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_erp/core/pdf/receipt_and_ledger_pdf_builder.dart';
import 'package:supermarket_erp/data/models/erp_and_sync_models.dart';
import 'package:supermarket_erp/data/services/scale_and_pos_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const parser = ScaleAndBarcodeParser();

  group('Iteration 2 scale and unit behavior', () {
    test('decodes the corrected EAN-13 label to PLU 1025 and 1.500 kg', () {
      final parsed = parser.parseScaleBarcode('2010250150002');
      expect(parsed, isNotNull);
      expect(parsed!.pluCode, '1025');
      expect(parsed.quantity, closeTo(1.5, 0.000001));
    });

    test('rejects the supplied sample because its EAN-13 check digit is invalid', () {
      expect(parser.parseScaleBarcode('2010250150003'), isNull);
    });

    test('converts a carton of 24 units to base stock quantity', () {
      const cart = PosCartItemModel(
        productId: 'milk',
        unitId: 'carton-24',
        productName: 'حليب',
        unitName: 'كرتون 24',
        conversionFactor: 24,
        quantity: 1,
        unitPrice: 6200,
      );
      expect(cart.baseQuantity, 24);
    });
  });

  group('Iteration 2 PDF builders', () {
    test('creates an official party statement PDF without opening the print dialog', () async {
      final bytes = await ReceiptAndLedgerPdfBuilder.previewPartyStatement(
        party: const PartyModel(
          id: 'customer-test',
          partyType: 'CUSTOMER',
          code: 'C-TEST',
          nameAr: 'عميل تجريبي',
        ),
        entries: const [
          {
            'id': 'ledger-1',
            'party_id': 'customer-test',
            'entry_date': '2026-11-10T10:00:00Z',
            'entry_type': 'SALE',
            'alayh_amount': 100,
            'lah_amount': 0,
            'statement_ar': 'فاتورة اختبار',
            'doc_id': 'invoice-1',
          },
          {
            'id': 'ledger-2',
            'party_id': 'customer-test',
            'entry_date': '2026-11-10T11:00:00Z',
            'entry_type': 'RECEIPT',
            'alayh_amount': 0,
            'lah_amount': 40,
            'statement_ar': 'سند قبض اختبار',
            'doc_id': 'voucher-1',
          },
        ],
        totalAlayh: 100,
        totalLah: 40,
        printAfterGenerate: false,
      );
      expect(bytes, isNotEmpty);
      expect(bytes.take(4).toList(), [0x25, 0x50, 0x44, 0x46]);
    });

    test('creates a thermal receipt PDF with invoice barcode', () async {
      final bytes = await ThermalReceiptBuilder.build(
        storeName: 'سوبر ماركت تجريبي',
        invoiceNo: 'S-000001',
        invoiceDate: DateTime.utc(2026, 11, 10),
        items: const [
          ThermalReceiptItem(
            name: 'حليب',
            unitName: 'كرتون',
            quantity: 1,
            unitPrice: 6200,
            lineTotal: 6200,
          ),
        ],
        netTotal: 6200,
        paidTotal: 6200,
        changeReturned: 0,
        remainingAlayh: 0,
      );
      expect(bytes, isNotEmpty);
      expect(bytes.take(4).toList(), [0x25, 0x50, 0x44, 0x46]);
    });
  });
}
