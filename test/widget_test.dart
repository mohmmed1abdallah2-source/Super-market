import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_erp/main.dart';

void main() {
  test('root application widget uses the declared app class', () {
    const app = SupermarketErpApp();

    expect(app, isA<SupermarketErpApp>());
  });
}
