import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../lib/features/ledger/application/ledger_use_cases.dart';
import '../lib/features/ledger/data/postgres_ledger_repository.dart';
import '../lib/features/ledger/presentation/ledger_routes.dart';
import '../lib/features/sales_and_sync/application/sales_sync_use_cases.dart';
import '../lib/features/sales_and_sync/data/postgres_sales_sync_repository.dart';
import '../lib/features/sales_and_sync/presentation/sales_sync_routes.dart';
import '../lib/features/inventory_and_purchases/data/postgres_inventory_purchases_read_repository.dart';
import '../lib/features/inventory_and_purchases/presentation/inventory_purchases_routes.dart';

/// Starts the Supermarket ERP HTTP API.
Future<void> main(List<String> arguments) async {
  final environment = Platform.environment;
  final database = PostgreSQLConnection(
    _requiredEnvironment(environment, 'PGHOST'),
    int.tryParse(environment['PGPORT'] ?? '5432') ?? 5432,
    _requiredEnvironment(environment, 'PGDATABASE'),
    username: _requiredEnvironment(environment, 'PGUSER'),
    password: _requiredEnvironment(environment, 'PGPASSWORD'),
    timeoutInSeconds: 30,
  );
  await database.open();

  final branchTokens = _readBranchTokens(environment);
  final ledgerRepository = PostgresLedgerRepository(database);
  final salesRepository = PostgresSalesSyncRepository(database);
  final inventoryRepository = PostgresInventoryPurchasesReadRepository(database);

  final ledgerRouter = LedgerRoutes(
    createParty: CreatePartyUseCase(ledgerRepository),
    listParties: ListPartiesWithBalanceUseCase(ledgerRepository),
    getStatement: GetPartyStatementUseCase(ledgerRepository),
    postVoucher: PostVoucherUseCase(ledgerRepository),
    listVouchers: ListVouchersUseCase(ledgerRepository),
    listCashAccounts: ListCashAccountsUseCase(ledgerRepository),
    branchTokens: branchTokens,
  );

  final salesRouter = SalesSyncRoutes(
    postSale: PostSaleInvoiceUseCase(salesRepository),
    listSalesInvoices: ListSalesInvoicesUseCase(salesRepository),
    processBatch: ProcessSyncBatchUseCase(salesRepository),
    branchTokens: branchTokens,
  );

  final inventoryRouter = InventoryPurchasesRoutes(
    repository: inventoryRepository,
    branchTokens: branchTokens,
  );

  final root = Router();
  root.get('/health', (Request request) => Response.ok(
        jsonEncode({'status': 'ok', 'service': 'supermarket-erp-api'}),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      ));

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(Cascade()
          .add(root)
          .add(ledgerRouter.router)
          .add(salesRouter.router)
          .add(inventoryRouter.router)
          .handler);

  final host = environment['ERP_HOST'] ?? '0.0.0.0';
  final port = int.tryParse(environment['PORT'] ?? '8080') ?? 8080;
  final server = await shelf_io.serve(handler, host, port);
  stdout.writeln('Supermarket ERP API listening on ${server.address.address}:${server.port}');

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close(force: true);
    await database.close();
    exit(0);
  });
}

String _requiredEnvironment(Map<String, String> environment, String key) {
  final value = environment[key];
  if (value == null || value.trim().isEmpty) {
    throw StateError('Required environment variable $key is missing.');
  }
  return value.trim();
}

Map<String, String> _readBranchTokens(Map<String, String> environment) {
  final encoded = environment['ERP_BRANCH_TOKENS'];
  if (encoded != null && encoded.trim().isNotEmpty) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ERP_BRANCH_TOKENS must be a JSON object.');
    }
    final tokens = <String, String>{};
    for (final entry in decoded.entries) {
      if (entry.key.trim().isEmpty || entry.value is! String || (entry.value as String).isEmpty) {
        throw const FormatException('Every branch token must have a non-empty branch ID and token.');
      }
      tokens[entry.key] = entry.value as String;
    }
    if (tokens.isNotEmpty) return tokens;
  }
  final developmentToken = environment['ERP_API_TOKEN'];
  if (developmentToken != null && developmentToken.trim().isNotEmpty) {
    return {'branch-main': developmentToken.trim()};
  }
  throw StateError('Set ERP_BRANCH_TOKENS or ERP_API_TOKEN for branch-main.');
}
