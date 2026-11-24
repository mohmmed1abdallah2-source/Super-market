import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

import '../domain/control_plane_domain.dart';
import '../domain/control_plane_sessions.dart';

/// Resolves the caller from a control-plane session and enforces the active
/// store, current membership, operation permission and trusted branch mapping.
final class ControlPlaneOperationalAccess {
  const ControlPlaneOperationalAccess(this.sessions);

  final ControlPlaneSessionRepository? sessions;

  Middleware get middleware => (innerHandler) {
        return (request) async {
          final repository = sessions;
          if (repository == null) {
            return _json(503, 'CONTROL_PLANE_UNAVAILABLE',
                'Operational APIs are disabled until control-plane sessions are configured.');
          }
          final authorization = request.headers['authorization'];
          if (authorization == null ||
              !authorization.startsWith('Bearer ') ||
              authorization.length <= 7) {
            return _json(401, 'UNAUTHORIZED', 'A valid account session is required.');
          }
          final token = authorization.substring(7).trim();
          final hash = sha256.convert(utf8.encode(token)).toString();
          final session = await repository.findSession(hash);
          if (session == null) {
            return _json(401, 'UNAUTHORIZED', 'The account session is invalid or expired.');
          }
          final activeStore = session.activeStore;
          if (activeStore == null || activeStore.storeStatus != ControlPlaneStoreStatus.active) {
            return _json(409, 'ACTIVE_STORE_REQUIRED',
                'Select an active store with a ready database before using operational APIs.');
          }

          final requestedStore = request.headers['x-store-id'];
          if (requestedStore != null && requestedStore.trim() != activeStore.storeId) {
            return _json(403, 'STORE_CONTEXT_MISMATCH',
                'The requested store does not match the store selected in this session.');
          }

          final branchId = request.headers['x-branch-id'];
          if (branchId == null || branchId.trim().isEmpty) {
            return _json(400, 'BRANCH_REQUIRED', 'X-Branch-Id is required.');
          }
          final branchAllowed = await repository.isBranchAssignedToStore(
            storeId: activeStore.storeId,
            branchId: branchId.trim(),
          );
          if (!branchAllowed) {
            return _json(403, 'BRANCH_OUTSIDE_ACTIVE_STORE',
                'The branch is not registered to the active store.');
          }

          final permission = _permissionFor(request);
          if (!activeStore.role.allows(permission)) {
            return _json(403, 'PERMISSION_DENIED',
                'The current membership role does not allow this operation.');
          }

          return innerHandler(request.change(context: {
            'controlPlane.accountId': session.accountId,
            'controlPlane.sessionId': session.sessionId,
            'controlPlane.storeId': activeStore.storeId,
            'controlPlane.branchId': branchId.trim(),
            'controlPlane.role': activeStore.role.name,
          }));
        };
      };

  StorePermission _permissionFor(Request request) {
    final path = request.url.path;
    if (request.method == 'GET' || request.method == 'HEAD') {
      return StorePermission.viewOperations;
    }
    if (path == '/v1/sync/batch' ||
        path.endsWith('/approve') ||
        path.endsWith('/disposals') ||
        path.endsWith('/transfers')) {
      return StorePermission.approveOperations;
    }
    return StorePermission.createOperations;
  }

  Response _json(int status, String code, String message) => Response(
        status,
        body: jsonEncode({'code': code, 'message': message}),
        headers: const {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
        },
      );
}
