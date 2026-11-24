import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../lib/features/control_plane/data/postgres_control_plane_repository.dart';
import '../lib/features/control_plane/data/google_identity_token_verifier.dart';
import '../lib/features/control_plane/presentation/control_plane_auth_routes.dart';
import '../lib/features/control_plane/presentation/control_plane_operational_access.dart';
import '../lib/features/ledger/application/ledger_use_cases.dart';
import '../lib/features/ledger/data/postgres_ledger_repository.dart';
import '../lib/features/ledger/presentation/ledger_routes.dart';
import '../lib/features/sales_and_sync/application/sales_sync_use_cases.dart';
import '../lib/features/sales_and_sync/data/postgres_sales_sync_repository.dart';
import '../lib/features/sales_and_sync/presentation/sales_sync_routes.dart';
import '../lib/features/inventory_and_purchases/application/purchase_invoice_posting.dart';
import '../lib/features/inventory_and_purchases/application/purchase_return_posting.dart';
import '../lib/features/inventory_and_purchases/data/postgres_inventory_purchases_read_repository.dart';
import '../lib/features/inventory_and_purchases/data/postgres_inventory_approval_repository.dart';
import '../lib/features/inventory_and_purchases/data/postgres_purchase_invoice_posting_repository.dart';
import '../lib/features/inventory_and_purchases/data/postgres_purchase_return_posting_repository.dart';
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

  PostgreSQLConnection? controlPlaneDatabase;
  ControlPlaneAuthRoutes? controlPlaneAuthRoutes;
  PostgresControlPlaneRepository? controlPlaneRepository;
  if ((environment['ERP_CONTROL_PLANE_PGHOST'] ?? '').trim().isNotEmpty) {
    controlPlaneDatabase = PostgreSQLConnection(
      _requiredEnvironment(environment, 'ERP_CONTROL_PLANE_PGHOST'),
      int.tryParse(environment['ERP_CONTROL_PLANE_PGPORT'] ?? '5432') ?? 5432,
      _requiredEnvironment(environment, 'ERP_CONTROL_PLANE_PGDATABASE'),
      username: _requiredEnvironment(environment, 'ERP_CONTROL_PLANE_PGUSER'),
      password: _requiredEnvironment(environment, 'ERP_CONTROL_PLANE_PGPASSWORD'),
      timeoutInSeconds: 30,
    );
    await controlPlaneDatabase.open();
    controlPlaneRepository = PostgresControlPlaneRepository(controlPlaneDatabase);
    controlPlaneAuthRoutes = ControlPlaneAuthRoutes(
      identityVerifier: GoogleIdentityTokenVerifier(
        clientId: _requiredEnvironment(environment, 'ERP_GOOGLE_OAUTH_CLIENT_ID'),
      ),
      storeRepository: controlPlaneRepository,
      sessionRepository: controlPlaneRepository,
    );
  }

  const branchTokens = <String, String>{};
  final ledgerRepository = PostgresLedgerRepository(database);
  final salesRepository = PostgresSalesSyncRepository(database);
  final inventoryRepository = PostgresInventoryPurchasesReadRepository(database);
  final inventoryApprovalRepository = PostgresInventoryApprovalRepository(database);
  final purchasePostingRepository =
      PostgresPurchaseInvoicePostingRepository(database);
  final purchaseReturnPostingRepository =
      PostgresPurchaseReturnPostingRepository(database);

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
    postPurchaseInvoice: PostPurchaseInvoiceUseCase(purchasePostingRepository),
    postPurchaseReturn:
        PostPurchaseReturnUseCase(purchaseReturnPostingRepository),
    processSyncBatch: ProcessSyncBatchUseCase(salesRepository),
    createStocktakingSession: inventoryApprovalRepository.createStocktakeSession,
    branchTokens: branchTokens,
  );

  final root = Router();
  root.get('/health', (Request request) => Response.ok(
        jsonEncode({'status': 'ok', 'service': 'supermarket-erp-api'}),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      ));

  final operationalRoutes = Cascade()
      .add(ledgerRouter.router)
      .add(salesRouter.router)
      .add(inventoryRouter.router);
  final securedOperationalRoutes = Pipeline()
      .addMiddleware(ControlPlaneOperationalAccess(controlPlaneRepository).middleware)
      .addHandler(operationalRoutes.handler);

  var cascade = Cascade()
      .add(root);
  if (controlPlaneAuthRoutes != null) {
    cascade = cascade.add(controlPlaneAuthRoutes.router);
  }
  cascade = cascade.add(securedOperationalRoutes);
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(cascade.handler);

  final host = environment['ERP_HOST'] ?? '0.0.0.0';
  final port = int.tryParse(environment['PORT'] ?? '8080') ?? 8080;
  final server = await shelf_io.serve(handler, host, port);
  stdout.writeln('Supermarket ERP API listening on ${server.address.address}:${server.port}');

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close(force: true);
    await database.close();
    await controlPlaneDatabase?.close();
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

