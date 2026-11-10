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

  final token = _requiredEnvironment(environment, 'ERP_API_TOKEN');
  final ledgerRepository = PostgresLedgerRepository(database);
  final salesRepository = PostgresSalesSyncRepository(database);

  final ledgerRouter = LedgerRoutes(
    createParty: CreatePartyUseCase(ledgerRepository),
    listParties: ListPartiesWithBalanceUseCase(ledgerRepository),
    getStatement: GetPartyStatementUseCase(ledgerRepository),
    postVoucher: PostVoucherUseCase(ledgerRepository),
    listVouchers: ListVouchersUseCase(ledgerRepository),
    listCashAccounts: ListCashAccountsUseCase(ledgerRepository),
    apiToken: token,
  );

  final salesRouter = SalesSyncRoutes(
    postSale: PostSaleInvoiceUseCase(salesRepository),
    processBatch: ProcessSyncBatchUseCase(salesRepository),
    apiToken: token,
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
