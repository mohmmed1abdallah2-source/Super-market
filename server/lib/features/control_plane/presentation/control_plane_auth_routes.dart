import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../domain/control_plane_domain.dart';
import '../domain/control_plane_sessions.dart';

/// Account login, store discovery and active-store session selection.
final class ControlPlaneAuthRoutes {
  ControlPlaneAuthRoutes({
    required this.identityVerifier,
    required this.storeRepository,
    required this.sessionRepository,
    this.sessionLifetime = const Duration(hours: 12),
  });

  final AccountIdentityTokenVerifier identityVerifier;
  final ControlPlaneRepository storeRepository;
  final ControlPlaneSessionRepository sessionRepository;
  final Duration sessionLifetime;
  static const _uuid = Uuid();

  Router get router {
    final router = Router();
    router.post('/v1/auth/login', _login);
    router.post('/v1/auth/logout', _logout);
    router.get('/v1/stores', _listStores);
    router.post('/v1/stores/<storeId>/activate', _activateStore);
    return router;
  }

  Future<Response> _login(Request request) async => _guard(() async {
        final body = await _readBody(request);
        final provider = _required(body, 'provider').toLowerCase();
        final idToken = _required(body, 'idToken');
        final identity = await identityVerifier.verify(provider: provider, idToken: idToken);
        identity.validate();
        final accountId = await storeRepository.resolveVerifiedAccount(identity);
        final rawToken = _newToken();
        final expiresAt = DateTime.now().toUtc().add(sessionLifetime);
        await sessionRepository.createSession(
          sessionId: _uuid.v4(),
          accountId: accountId,
          accessTokenHash: _hash(rawToken),
          expiresAt: expiresAt,
        );
        final stores = await storeRepository.listActiveStores(accountId);
        return _json(200, {
          'accessToken': rawToken,
          'tokenType': 'Bearer',
          'expiresAt': expiresAt.toIso8601String(),
          'accountId': accountId,
          'stores': stores.map(_storeJson).toList(growable: false),
        });
      });

  Future<Response> _listStores(Request request) async => _guard(() async {
        final session = await _authenticatedSession(request);
        final stores = await storeRepository.listActiveStores(session.accountId);
        return _json(200, {'items': stores.map(_storeJson).toList(growable: false)});
      });

  Future<Response> _activateStore(Request request) async => _guard(() async {
        final session = await _authenticatedSession(request);
        final storeId = request.params['storeId'];
        if (storeId == null || storeId.trim().isEmpty) {
          throw const FormatException('A store ID is required.');
        }
        final store = await sessionRepository.activateStore(
          accessTokenHash: _hash(_bearer(request)),
          storeId: storeId,
        );
        return _json(200, {
          'activeStore': _storeJson(store),
          'accountId': session.accountId,
        });
      });

  Future<Response> _logout(Request request) async => _guard(() async {
        _bearer(request);
        await sessionRepository.revokeSession(_hash(_bearer(request)));
        return _json(200, {'status': 'signed_out'});
      });

  Future<ControlPlaneSession> _authenticatedSession(Request request) async {
    final token = _bearer(request);
    final session = await sessionRepository.findSession(_hash(token));
    if (session == null || !session.expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const _Unauthorized();
    }
    return session;
  }

  String _bearer(Request request) {
    final value = request.headers['authorization'];
    if (value == null || !value.startsWith('Bearer ') || value.length <= 7) {
      throw const _Unauthorized();
    }
    return value.substring(7).trim();
  }

  String _newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _hash(String token) => sha256.convert(utf8.encode(token)).toString();

  Map<String, Object?> _storeJson(AccountStoreAccess store) => {
        'storeId': store.storeId,
        'displayName': store.displayName,
        'role': store.role.name,
        'status': store.storeStatus.name,
        'canActivate': store.canActivate,
      };

  Future<Map<String, dynamic>> _readBody(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) throw const FormatException('A JSON request body is required.');
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Request body must be a JSON object.');
    }
    return value;
  }

  String _required(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required.');
    }
    return value.trim();
  }

  Future<Response> _guard(Future<Response> Function() action) async {
    try {
      return await action();
    } on _Unauthorized {
      return _json(401, {'code': 'UNAUTHORIZED', 'message': 'A valid account session is required.'});
    } on FormatException catch (error) {
      return _json(422, {'code': 'VALIDATION_ERROR', 'message': error.message});
    } on ArgumentError catch (error) {
      return _json(422, {'code': 'VALIDATION_ERROR', 'message': error.message.toString()});
    } on StateError catch (error) {
      final message = error.message;
      final status = message.contains('not active') || message.contains('not accepting')
          ? 403
          : 409;
      return _json(status, {'code': 'BUSINESS_RULE_VIOLATION', 'message': message});
    } catch (_) {
      return _json(500, {'code': 'INTERNAL_ERROR', 'message': 'The request could not be completed.'});
    }
  }

  Response _json(int status, Object body) => Response(
        status,
        body: jsonEncode(body),
        headers: const {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'},
      );
}

final class _Unauthorized implements Exception {
  const _Unauthorized();
}
