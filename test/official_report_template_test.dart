import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_erp/core/pdf/official_report_template.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OfficialReportTemplate', () {
    test('generates a PDF using the bundled Arabic fonts', () async {
      final bytes = await OfficialReportTemplate.preview(
        reportTitle: 'تقرير تجريبي',
        summaryBoxes: const [],
        columns: const ['الصنف', 'الكمية'],
        rows: const [
          ['حليب', '12'],
          ['جبن', '5'],
        ],
        minTableRows: 0,
        printAfterGenerate: false,
      );

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('supports a cards-only report without table columns', () async {
      final bytes = await OfficialReportTemplate.preview(
        reportTitle: 'ملخص إحصائي',
        summaryBoxes: const [
          StatBoxData(number: '1', title: 'إجمالي المبيعات', value: '1250'),
        ],
        columns: const [],
        rows: const [],
        cardsOnly: true,
        printAfterGenerate: false,
      );

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });
  });
}
