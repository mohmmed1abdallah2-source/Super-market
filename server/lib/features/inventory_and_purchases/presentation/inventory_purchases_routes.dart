import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../data/postgres_inventory_purchases_read_repository.dart';

/// Read endpoints for the existing branch-scoped inventory/purchase API.
final class InventoryPurchasesRoutes {
  const InventoryPurchasesRoutes({
    required this.repository,
    required this.branchTokens,
  });

  final PostgresInventoryPurchasesReadRepository repository;
  final Map<String, String> branchTokens;

  Router get router {
    final router = Router();
    router.get('/v1/inventory/warehouses', _listWarehouses);
    router.get('/v1/inventory/locations', _listLocations);
    router.get('/v1/inventory/batches', _listBatches);
    router.get('/v1/inventory/movements', _listMovements);
    router.get('/v1/inventory/stocktaking', _listStocktaking);
    router.get('/v1/purchases/shortages', _listShortages);
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

  Future<Response> _listShortages(Request request) => _guard(
        request,
        () async => _ok({
          'items': await repository.listShortageSuggestions(
            branchId: _branchId(request),
          ),
        }),
      );

  Future<Response> _guard(
    Request request,
    Future<Response> Function() action,
  ) async {
    final branch = request.headers['x-branch-id'];
    final expectedToken = branch == null ? null : branchTokens[branch];
    if (expectedToken == null ||
        request.headers['authorization'] != 'Bearer $expectedToken') {
      return _json(401, {
        'code': 'UNAUTHORIZED',
        'message': 'A valid branch-scoped bearer token is required.',
      });
    }
    try {
      return await action();
    } on FormatException catch (error) {
      return _json(422, {
        'code': 'VALIDATION_ERROR',
        'message': error.message,
      });
    } catch (_) {
      return _json(500, {
        'code': 'INTERNAL_ERROR',
        'message': 'The request could not be completed.',
      });
    }
  }

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
