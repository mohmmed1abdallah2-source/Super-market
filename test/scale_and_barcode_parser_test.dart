import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_erp/data/services/scale_and_pos_service.dart';

void main() {
  const parser = ScaleAndBarcodeParser();

  group('ScaleAndBarcodeParser', () {
    test('decodes a valid EAN-13 scale label into PLU and kilogram quantity', () {
      final result = parser.parseScaleBarcode('2010250125000');

      expect(result, isNotNull);
      expect(result!.pluCode, '1025');
      expect(result.quantity, closeTo(1.25, 0.000001));
      expect(result.quantityUnit, 'كيلو');
    });

    test('rejects a scale label with an invalid EAN-13 check digit', () {
      expect(parser.parseScaleBarcode('2010250125009'), isNull);
    });

    test('does not treat a regular product EAN as a scale label', () {
      expect(parser.parseScaleBarcode('6281000001002'), isNull);
    });

    test('validates EAN-13 check digit independently', () {
      expect(parser.isValidEan13('2010250125000'), isTrue);
      expect(parser.isValidEan13('2010250125009'), isFalse);
      expect(parser.isValidEan13('201025012500'), isFalse);
    });
  });
}