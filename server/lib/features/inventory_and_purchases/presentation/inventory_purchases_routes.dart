import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../application/purchase_invoice_posting.dart';
import '../application/purchase_return_posting.dart';
import '../data/postgres_inventory_purchases_read_repository.dart';
import '../../sales_and_sync/application/sales_sync_use_cases.dart';
import '../../sales_and_sync/domain/sales_sync_domain.dart';

/// Read endpoints for the existing branch-scoped inventory/purchase API.
final class InventoryPurchasesRoutes {
  const InventoryPurchasesRoutes({
    required this.repository,
    required this.postPurchaseInvoice,
    required this.postPurchaseReturn,
    required this.processSyncBatch,
    required this.createStocktakingSession,
    required this.branchTokens,
  });

  final PostgresInventoryPurchasesReadRepository repository;
  final PostPurchaseInvoiceUseCase postPurchaseInvoice;
  final PostPurchaseReturnUseCase postPurchaseReturn;
  final ProcessSyncBatchUseCase processSyncBatch;
  final Future<Map<String, Object?>> Function({
    required String branchId,
    required Map<String, dynamic> payload,
  }) createStocktakingSession;
  final Map<String, String> branchTokens;

  Router get router {
    final router = Router();
    router.get('/v1/inventory/warehouses', _listWarehouses);
    router.get('/v1/inventory/locations', _listLocations);
    router.get('/v1/inventory/batches', _listBatches);
    router.get('/v1/inventory/movements', _listMovements);
    router.get('/v1/inventory/stocktaking', _listStocktaking);
    router.post('/v1/inventory/stocktaking', _createStocktaking);
    router.post('/v1/inventory/stocktaking/<sessionId>/approve', _approveStocktake);
    router.post('/v1/inventory/disposals', _approveDisposal);
    router.post('/v1/inventory/transfers', _executeStockTransfer);
    router.get('/v1/purchases/shortages', _listShortages);
    router.post('/v1/purchases/invoices', _postPurchaseInvoice);
    router.post('/v1/purchases/returns', _postPurchaseReturn);
    return router;
  }

  Future<Response> _listWarehouses(Request request) => _guard(
        request,
        () async => _ok({
          'items': await repository.listWarehouses(branchId: _branchId(request)),
        }),
      );

  Future<Response> _listLocations(Request request) => _guard(
        request,
        () async => _ok({
          'items': await repository.listLocations(
            branchId: _branchId(request),
            warehouseId: request.url.queryParameters['warehouseId'],
          ),
        }),
      );

  Future<Response> _listBatches(Request request) => _guard(
        request,
        () async => _ok({
          'items': await repository.listBatches(
            branchId: _branchId(request),
            productId: request.url.queryParameters['productId'],
            warehouseId: request.url.queryParameters['warehouseId'],
            includeInactive: request.url.queryParameters['includeInactive'] == 'true',
          ),
        }),
      );

  Future<Response> _listMovements(Request request) => _guard(
        request,
        () async => _ok({
          'items': await repository.listMovements(
            branchId: _branchId(request),
            productId: request.url.queryParameters['productId'],
            warehouseId: request.url.queryParameters['warehouseId'],
            from: _date(request.url.queryParameters['from']),
            to: _date(request.url.queryParameters['to']),
          ),
        }),
      );

  Future<Response> _listStocktaking(Request request) => _guard(
        request,
        () async => _ok({
          'items': await repository.listStocktakingSessions(
            branchId: _branchId(request),
          ),
        }),
      );


  Future<Response> _createStocktaking(Request request) => _guard(
        request,
        () async {
          final body = await _body(request);
          // Stable sessionId and line IDs make an identical retry safe.
          _idempotencyKey(request);
          final result = await createStocktakingSession(
            branchId: _branchId(request),
            payload: body,
          );
          return _json(result['replayed'] == true ? 200 : 201, result);
        },
      );

  Future<Response> _listShortages(Request request) => _guard(
        request,
        () async => _ok({
          'items': await repository.listShortageSuggestions(
            branchId: _branchId(request),
          ),
        }),
      );

  Future<Response> _approveStocktake(Request request) => _guard(
        request,
        () async {
          final body = await _body(request);
          body['sessionId'] = request.params['sessionId'];
          return _processApproval(request, body, 'STOCKTAKE_APPROVE');
        },
      );

  Future<Response> _approveDisposal(Request request) => _guard(
        request,
        () async {
          final body = await _body(request);
          body['disposalId'] ??= body['id'];
          return _processApproval(request, body, 'DISPOSAL_APPROVE');
        },
      );

  Future<Response> _executeStockTransfer(Request request) => _guard(
        request,
        () async {
          final body = await _body(request);
          body['transferId'] ??= body['id'];
          return _processApproval(request, body, 'STOCK_TRANSFER');
        },
      );

  Future<Response> _processApproval(
    Request request,
    Map<String, dynamic> body,
    String operationType,
  ) async {
    final operationId = (body['operationId'] as String?)?.trim().isNotEmpty == true
        ? (body['operationId'] as String).trim()
        : _idempotencyKey(request);
    final result = await processSyncBatch(SyncBatchCommand(
      branchId: _branchId(request),
      batchId: operationId,
      idempotencyKey: _idempotencyKey(request),
      requestHash: _hash(body),
      operations: [
        SyncOperation(
          operationId: operationId,
          operationType: operationType,
          payload: body,
        ),
      ],
    ));
    final results = result['results'];
    if (results is Map && results[operationId] is Map) {
      return _json(200, Map<String, dynamic>.from(results[operationId] as Map));
    }
    return _json(200, result);
  }

  Future<Response> _postPurchaseInvoice(Request request) => _guard(
        request,
        () async {
          final body = await _body(request);
          final command = PurchaseInvoiceCommand(
            branchId: _branchId(request),
            operationId: _requiredText(body, 'operationId'),
            request: body,
            idempotencyKey: _idempotencyKey(request),
            requestHash: _hash(body),
          );
          return _json(201, await postPurchaseInvoice(command));
        },
      );

  Future<Response> _postPurchaseReturn(Request request) => _guard(
        request,
        () async {
          final body = await _body(request);
          final command = PurchaseReturnCommand(
            branchId: _branchId(request),
            operationId: _requiredText(body, 'operationId'),
            request: body,
            idempotencyKey: _idempotencyKey(request),
            requestHash: _hash(body),
          );
          return _json(201, await postPurchaseReturn(command));
        },
      );


  Future<Response> _guard(
    Request request,
    Future<Response> Function() action,
  ) async {
    // ControlPlaneOperationalAccess validates the account session, store,
    // active membership, operation permission and branch ownership.
    try {
      return await action();
    } on FormatException catch (error) {
      return _json(422, {
        'code': 'VALIDATION_ERROR',
        'message': error.message,
      });
    } on StateError catch (error) {
      final message = error.message;
      final conflict = message == 'IDEMPOTENCY_KEY_REUSED' ||
          message == 'OPERATION_ID_REUSED';
      return _json(conflict ? 409 : 422, {
        'code': conflict
            ? (message == 'OPERATION_ID_REUSED'
                ? 'OPERATION_ID_REUSED'
                : 'IDEMPOTENCY_KEY_REUSED')
            : 'BUSINESS_RULE_VIOLATION',
        'message': message,
      });
    } catch (_) {
      return _json(500, {
        'code': 'INTERNAL_ERROR',
        'message': 'The request could not be completed.',
      });
    }
  }

  Future<Map<String, dynamic>> _body(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) throw const FormatException('JSON request body is required.');
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Request body must be a JSON object.');
    }
    return decoded;
  }

  String _requiredText(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required.');
    }
    return value.trim();
  }

  String _idempotencyKey(Request request) {
    final value = request.headers['idempotency-key'];
    if (value == null || value.trim().length < 16 || value.trim().length > 200) {
      throw const FormatException('A valid Idempotency-Key header is required.');
    }
    return value.trim();
  }

  String _hash(Map<String, dynamic> body) =>
      sha256.convert(utf8.encode(jsonEncode(body))).toString();

  String _branchId(Request request) {
    final value = request.headers['x-branch-id'];
    if (value == null || value.trim().isEmpty) {
      throw const FormatException('X-Branch-Id header is required.');
    }
    return value.trim();
  }

  DateTime? _date(String? value) =>
      value == null || value.isEmpty ? null : DateTime.parse(value).toUtc();

  Response _ok(Object body) => _json(200, body);

  Response _json(int status, Object body) => Response(
        status,
        body: jsonEncode(body),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
}
