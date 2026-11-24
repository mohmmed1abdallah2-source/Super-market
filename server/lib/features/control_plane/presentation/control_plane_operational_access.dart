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

          var operationalRequest = request;
          final permission = await _permissionForRequest(request, (replayed) {
            operationalRequest = replayed;
          });
          if (!activeStore.role.allows(permission)) {
            return _json(403, 'PERMISSION_DENIED',
                'The current membership role does not allow this operation.');
          }

          return innerHandler(operationalRequest.change(context: {
            'controlPlane.accountId': session.accountId,
            'controlPlane.sessionId': session.sessionId,
            'controlPlane.storeId': activeStore.storeId,
            'controlPlane.branchId': branchId.trim(),
            'controlPlane.role': activeStore.role.name,
          }));
        };
      };

  Future<StorePermission> _permissionForRequest(
    Request request,
    void Function(Request replayed) replaceRequest,
  ) async {
    final path = request.url.path;
    if (request.method == 'GET' || request.method == 'HEAD') {
      return StorePermission.viewOperations;
    }
    if (path.endsWith('/approve') ||
        path.endsWith('/disposals') ||
        path.endsWith('/transfers')) {
      return StorePermission.approveOperations;
    }
    if (request.method == 'POST' && path == '/v1/sync/batch') {
      // Sync batches can mix ordinary creates with privileged approvals.
      // Inspect the operation types before authorizing, then replay the exact
      // body to the route handler because middleware consumed the stream.
      final rawBody = await request.readAsString();
      replaceRequest(request.change(body: rawBody));
      try {
        final decoded = jsonDecode(rawBody);
        final operations = decoded is Map<String, dynamic> ? decoded['operations'] : null;
        if (operations is List) {
          const approvalTypes = {
            'STOCKTAKE_APPROVE',
            'DISPOSAL_APPROVE',
            'STOCK_TRANSFER',
          };
          for (final operation in operations) {
            if (operation is Map<String, dynamic> &&
                approvalTypes.contains(operation['operationType']?.toString().toUpperCase())) {
              return StorePermission.approveOperations;
            }
          }
        }
      } on FormatException {
        // Let the route handler return its normal validation response.
      }
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
