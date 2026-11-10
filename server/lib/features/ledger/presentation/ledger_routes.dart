import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../application/ledger_use_cases.dart';
import '../data/postgres_ledger_repository.dart';
import '../domain/ledger_domain.dart';

/// HTTP routes for parties, party statements, vouchers and cash accounts.
class LedgerRoutes {
  /// Creates route handlers around the ledger application use cases.
  LedgerRoutes({
    required this.createParty,
    required this.listParties,
    required this.getStatement,
    required this.postVoucher,
    required this.listVouchers,
    required this.listCashAccounts,
    required this.apiToken,
  });

  final CreatePartyUseCase createParty;
  final ListPartiesWithBalanceUseCase listParties;
  final GetPartyStatementUseCase getStatement;
  final PostVoucherUseCase postVoucher;
  final ListVouchersUseCase listVouchers;
  final ListCashAccountsUseCase listCashAccounts;
  final String apiToken;

  /// Builds a Shelf router for the ledger endpoints.
  Router get router {
    final router = Router();
    router.get('/v1/parties', _listParties);
    router.post('/v1/parties', _createParty);
    router.get('/v1/parties/<id>/statement', _getStatement);
    router.get('/v1/ledger/vouchers', _listVouchers);
    router.post('/v1/ledger/vouchers', _postVoucher);
    router.get('/v1/ledger/cash-accounts', _listCashAccounts);
    return router;
  }

  Future<Response> _listParties(Request request) async => _guard(request, () async {
        final branch = _branchId(request);
        final query = request.url.queryParameters;
        final result = await listParties(
          branchId: branch,
          partyType: query['partyType'],
          limit: int.tryParse(query['limit'] ?? '50') ?? 50,
          cursor: query['cursor'],
        );
        return _json(200, {'items': result});
      });

  Future<Response> _createParty(Request request) async => _guard(request, () async {
        final branch = _branchId(request);
        final key = _idempotencyKey(request);
        final body = await _body(request);
        final command = CreatePartyCommand(
          branchId: branch,
          partyType: _partyType(body['partyType']),
          code: _requiredText(body, 'code'),
          name: _requiredText(body, 'name'),
          phone: body['phone'] as String?,
          address: body['address'] as String?,
          creditLimit: _decimal(body['creditLimit']),
          paymentTermsDays: _integer(body['paymentTermsDays']),
          priceTier: (body['priceTier'] as String? ?? 'RETAIL').toUpperCase(),
        );
        final result = await createParty(
          command: command,
          idempotencyKey: key,
          requestHash: PostgresLedgerRepository.hashRequest(body),
        );
        return _json(201, result);
      });

  Future<Response> _getStatement(Request request, String id) async =>
      _guard(request, () async {
        final query = request.url.queryParameters;
        final result = await getStatement(
          branchId: _branchId(request),
          partyId: id,
          from: _date(query['from']),
          to: _date(query['to']),
          limit: int.tryParse(query['limit'] ?? '100') ?? 100,
          cursor: query['cursor'],
        );
        return _json(200, result);
      });

  Future<Response> _listVouchers(Request request) async => _guard(request, () async {
        final query = request.url.queryParameters;
        final result = await listVouchers(
          branchId: _branchId(request),
          partyId: query['partyId'],
          voucherType: query['voucherType'],
          from: _date(query['from']),
          to: _date(query['to']),
        );
        return _json(200, {'items': result});
      });

  Future<Response> _postVoucher(Request request) async => _guard(request, () async {
        final branch = _branchId(request);
        final key = _idempotencyKey(request);
        final body = await _body(request);
        final type = _requiredText(body, 'voucherType').toUpperCase();
        if (type != 'RECEIPT' && type != 'PAYMENT') {
          throw const FormatException('Voucher type must be RECEIPT or PAYMENT.');
        }
        final command = PostVoucherCommand(
          branchId: branch,
          operationId: _requiredText(body, 'operationId'),
          voucherType: type == 'RECEIPT'
              ? LedgerVoucherType.receipt
              : LedgerVoucherType.payment,
          partyId: _requiredText(body, 'partyId'),
          cashAccountId: _requiredText(body, 'cashAccountId'),
          amount: _decimal(body['amount']),
          method: _requiredText(body, 'method').toUpperCase(),
          idempotencyKey: key,
          requestHash: PostgresLedgerRepository.hashRequest(body),
          walletRefNo: body['walletRefNo'] as String?,
          description: body['description'] as String? ?? '',
        );
        final result = await postVoucher(command);
        return _json(201, result);
      });

  Future<Response> _listCashAccounts(Request request) async =>
      _guard(request, () async {
        final result = await listCashAccounts(_branchId(request));
        return _json(200, {'items': result});
      });

  Future<Response> _guard(Request request, Future<Response> Function() action) async {
    if (apiToken.isEmpty ||
        request.headers['authorization'] != 'Bearer $apiToken') {
      return _json(401, {
        'code': 'UNAUTHORIZED',
        'message': 'Authentication is required.',
      });
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
    } catch (error) {
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
    if (value == null || value.trim().length < 16) {
      throw const FormatException('A valid Idempotency-Key header is required.');
    }
    return value.trim();
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

  LedgerPartyType _partyType(Object? value) {
    final normalized = value?.toString().toLowerCase();
    return LedgerPartyType.values.firstWhere(
      (item) => item.name == normalized,
      orElse: () => throw FormatException('Unsupported party type: $value'),
    );
  }

  String _requiredText(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required.');
    }
    return value.trim();
  }

  double _decimal(Object? value) {
    final result = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
    if (result == null || !result.isFinite) {
      throw FormatException('Invalid decimal value: $value');
    }
    return result;
  }

  int _integer(Object? value) {
    if (value == null) return 0;
    final result = value is num ? value.toInt() : int.tryParse(value.toString());
    if (result == null) throw FormatException('Invalid integer value: $value');
    return result;
  }

  DateTime? _date(String? value) =>
      value == null || value.isEmpty ? null : DateTime.parse(value).toUtc();

  Response _json(int status, Object body) => Response(
        status,
        body: jsonEncode(body),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
}
