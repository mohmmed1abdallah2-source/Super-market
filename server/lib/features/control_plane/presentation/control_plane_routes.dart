import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../data/postgres_control_plane_repository.dart';
import '../data/store_database_router.dart';

/// Identity and store-selection endpoints backed by the separate control plane.
final class ControlPlaneRoutes {
  const ControlPlaneRoutes(this._repository);

  final PostgresControlPlaneRepository _repository;

  Router get router {
    final router = Router();
    router.post('/v1/auth/sign-in', _signIn);
    router.get('/v1/stores', _listStores);
    router.post('/v1/stores/activate', _activateStore);
    router.post('/v1/auth/sign-out', _signOut);
    return router;
  }

  Future<Response> _signIn(Request request) async {
    try {
      final body = await _readBody(request);
      final email = _required(body, 'email');
      final password = _required(body, 'password');
      final ticket = await _repository.beginSignIn(
        email: email,
        password: password,
      );
      if (ticket == null) {
        return _json(401, {
          'code': 'INVALID_CREDENTIALS',
          'message': 'Email or password is incorrect.',
        });
      }
      return _json(200, {
        'accountId': ticket.accountId,
        'loginTicket': ticket.token,
        'expiresAt': ticket.expiresAt.toIso8601String(),
        'stores': ticket.memberships.map((item) => item.toJson()).toList(),
      });
    } on FormatException catch (error) {
      return _json(422, {'code': 'VALIDATION_ERROR', 'message': error.message});
    } catch (_) {
      return _json(500, {
        'code': 'INTERNAL_ERROR',
        'message': 'The sign-in request could not be completed.',
      });
    }
  }

  Future<Response> _listStores(Request request) async {
    final context = await _authenticatedContext(request);
    if (context == null) return _unauthorized();
    try {
      final stores = await _repository.listActiveMemberships(context.accountId);
      return _json(200, {'items': stores.map((item) => item.toJson()).toList()});
    } catch (_) {
      return _internalError();
    }
  }

  Future<Response> _activateStore(Request request) async {
    final ticket = _bearer(request);
    if (ticket == null) return _unauthorized();
    try {
      final body = await _readBody(request);
      final storeId = _required(body, 'storeId');
      final session = await _repository.activateStore(
        loginTicket: ticket,
        requestedStoreId: storeId,
      );
      if (session == null) {
        return _json(403, {
          'code': 'STORE_ACCESS_DENIED',
          'message': 'The account has no active membership in this store.',
        });
      }
      return _json(200, session.toJson());
    } on FormatException catch (error) {
      return _json(422, {'code': 'VALIDATION_ERROR', 'message': error.message});
    } catch (_) {
      return _internalError();
    }
  }

  Future<Response> _signOut(Request request) async {
    final context = await _authenticatedContext(request);
    if (context == null) return _unauthorized();
    try {
      await _repository.revokeSession(
        sessionId: context.sessionId,
        accountId: context.accountId,
      );
      return _json(200, {'revoked': true});
    } catch (_) {
      return _internalError();
    }
  }

  Future<StoreRequestContext?> _authenticatedContext(Request request) async {
    final token = _bearer(request);
    if (token == null) return null;
    try {
      return await _repository.resolveAccessToken(token);
    } catch (_) {
      return null;
    }
  }

  String? _bearer(Request request) {
    final value = request.headers['authorization'];
    if (value == null || !value.startsWith('Bearer ')) return null;
    final token = value.substring(7).trim();
    return token.isEmpty ? null : token;
  }

  Future<Map<String, dynamic>> _readBody(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) throw const FormatException('JSON body is required.');
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Request body must be a JSON object.');
    }
    return decoded;
  }

  String _required(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required.');
    }
    return value.trim();
  }

  Response _unauthorized() => _json(401, {
        'code': 'UNAUTHORIZED',
        'message': 'A valid bearer session is required.',
      });

  Response _internalError() => _json(500, {
        'code': 'INTERNAL_ERROR',
        'message': 'The request could not be completed.',
      });

  Response _json(int status, Object value) => Response(
        status,
        body: jsonEncode(value),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
}
