import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../application/sales_sync_use_cases.dart';
import '../domain/sales_sync_domain.dart';

/// HTTP handlers for sales invoices and offline batch synchronization.
class SalesSyncRoutes {
  /// Creates the route group.
  const SalesSyncRoutes({
    required this.postSale,
    required this.processBatch,
    required this.apiToken,
  });

  final PostSaleInvoiceUseCase postSale;
  final ProcessSyncBatchUseCase processBatch;
  final String apiToken;

  /// Builds the supported sales and sync endpoints.
  Router get router {
    final router = Router();
    router.post('/v1/sales/invoices', _postSale);
    router.post('/v1/sync/batch', _postBatch);
    return router;
  }

  Future<Response> _postSale(Request request) async => _guard(request, () async {
        final body = await _body(request);
        final command = SaleInvoiceCommand(
          branchId: _branchId(request),
          operationId: _required(body, 'operationId'),
          request: body,
          idempotencyKey: _idempotencyKey(request),
          requestHash: _hash(body),
        );
        final result = await postSale(command);
        return _json(201, result);
      });

  Future<Response> _postBatch(Request request) async => _guard(request, () async {
        final body = await _body(request);
        final rawOperations = body['operations'];
        if (rawOperations is! List) {
          throw const FormatException('operations must be a JSON array.');
        }
        final operations = rawOperations.map((raw) {
          if (raw is! Map<String, dynamic>) {
            throw const FormatException('Every operation must be a JSON object.');
          }
          final payload = raw['payload'];
          if (payload is! Map<String, dynamic>) {
            throw const FormatException('Every operation payload must be a JSON object.');
          }
          return SyncOperation(
            operationId: _required(raw, 'operationId'),
            operationType: _required(raw, 'operationType').toUpperCase(),
            payload: payload,
          );
        }).toList(growable: false);
        final command = SyncBatchCommand(
          branchId: _branchId(request),
          batchId: _required(body, 'batchId'),
          idempotencyKey: _idempotencyKey(request),
          requestHash: _hash(body),
          operations: operations,
        );
        final result = await processBatch(command);
        return _json(200, result);
      });

  Future<Response> _guard(Request request, Future<Response> Function() action) async {
    if (apiToken.isEmpty ||
        request.headers['authorization'] != 'Bearer $apiToken') {
      return _json(401, {'code': 'UNAUTHORIZED', 'message': 'Authentication is required.'});
    }
    try {
      return await action();
    } on FormatException catch (error) {
      return _json(422, {'code': 'VALIDATION_ERROR', 'message': error.message});
    } on RangeError catch (error) {
      return _json(422, {'code': 'VALIDATION_ERROR', 'message': error.toString()});
    } on StateError catch (error) {
      final message = error.message;
      final conflict = message == 'IDEMPOTENCY_KEY_REUSED';
      return _json(conflict ? 409 : 422, {
        'code': conflict ? 'IDEMPOTENCY_KEY_REUSED' : 'BUSINESS_RULE_VIOLATION',
        'message': message,
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

  String _idempotencyKey(Request request) {
    final value = request.headers['idempotency-key'];
    if (value == null || value.trim().length < 16 || value.trim().length > 200) {
      throw const FormatException('A valid Idempotency-Key header is required.');
    }
    return value.trim();
  }

  Future<Map<String, dynamic>> _body(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) throw const FormatException('JSON request body is required.');
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Request body must be a JSON object.');
    }
    return value;
  }

  String _required(Map<String, dynamic> value, String key) {
    final item = value[key];
    if (item is! String || item.trim().isEmpty) {
      throw FormatException('$key is required.');
    }
    return item.trim();
  }

  String _hash(Map<String, dynamic> body) =>
      sha256.convert(utf8.encode(jsonEncode(body))).toString();

  Response _json(int status, Object body) => Response(
        status,
        body: jsonEncode(body),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
}
