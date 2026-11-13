import 'dart:convert';

import 'package:core_contracts/core_contracts.dart';
import 'package:http/http.dart' as http;

/// Raised when the ERP API returns a non-success HTTP response.
class ApiClientException implements Exception {
  /// Creates a typed API error.
  const ApiClientException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details,
  });

  /// HTTP response status.
  final int statusCode;

  /// Stable machine-readable error code.
  final String code;

  /// Human-readable error message.
  final String message;

  /// Optional structured error details.
  final Map<String, dynamic>? details;

  @override
  String toString() => 'ApiClientException($statusCode, $code): $message';
}

/// HTTP client for the versioned Global Enterprise Supermarket API.
///
/// Every write method requires an explicit idempotency key. The caller must
/// persist and reuse that key when retrying the same logical operation.
class ApiClient {
  /// Creates an API client.
  ApiClient({
    required this.baseUri,
    required http.Client httpClient,
    required Future<String?> Function() accessTokenProvider,
    required Future<String?> Function() branchIdProvider,
    this.timeout = const Duration(seconds: 20),
  })  : _http = httpClient,
        _accessTokenProvider = accessTokenProvider,
        _branchIdProvider = branchIdProvider;

  /// API root URI, for example https://erp.example.com.
  final Uri baseUri;

  /// Request timeout.
  final Duration timeout;

  final http.Client _http;
  final Future<String?> Function() _accessTokenProvider;
  final Future<String?> Function() _branchIdProvider;

  /// Releases the underlying HTTP client.
  void close() => _http.close();

  /// Loads a page of parties with balances calculated from their ledger.
  Future<List<PartyDto>> listParties({
    PartyType? partyType,
    String? cursor,
    int limit = 50,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (partyType != null) query['partyType'] = enumToJson(partyType);
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final json = await _send('GET', '/v1/parties', query: query);
    final items = (json['items'] as List<dynamic>? ?? const []);
    return items
        .map((item) => PartyDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Creates a party and returns its initial calculated balance.
  Future<PartyDto> createParty({
    required Map<String, dynamic> request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/parties',
      body: request,
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return PartyDto.fromJson(json);
  }

  /// Retrieves the full statement page for one party.
  Future<PartyStatementDto> getPartyStatement(
    String partyId, {
    DateTime? from,
    DateTime? to,
    String? cursor,
    int limit = 100,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (from != null) query['from'] = from.toUtc().toIso8601String();
    if (to != null) query['to'] = to.toUtc().toIso8601String();
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final json = await _send(
      'GET',
      '/v1/parties/${Uri.encodeComponent(partyId)}/statement',
      query: query,
    );
    return PartyStatementDto.fromJson(json);
  }

  /// Lists vouchers, optionally filtered by party and date range.
  Future<List<VoucherDto>> listVouchers({
    String? partyId,
    VoucherType? voucherType,
    DateTime? from,
    DateTime? to,
  }) async {
    final query = <String, String>{};
    if (partyId != null) query['partyId'] = partyId;
    if (voucherType != null) query['voucherType'] = enumToJson(voucherType);
    if (from != null) query['from'] = from.toUtc().toIso8601String();
    if (to != null) query['to'] = to.toUtc().toIso8601String();
    final json = await _send('GET', '/v1/ledger/vouchers', query: query);
    final items = json['items'] as List<dynamic>? ?? json['data'] as List<dynamic>? ?? const [];
    return items
        .map((item) => VoucherDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Posts a voucher using a stable idempotency key.
  Future<VoucherDto> postVoucher({
    required Map<String, dynamic> request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/ledger/vouchers',
      body: request,
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return VoucherDto.fromJson(json);
  }

  /// Lists branch cash drawers and electronic wallets.
  Future<List<CashAccountDto>> listCashAccounts() async {
    final json = await _send('GET', '/v1/ledger/cash-accounts');
    final items = json['items'] as List<dynamic>? ?? json['data'] as List<dynamic>? ?? const [];
    return items
        .map((item) => CashAccountDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Posts a sales invoice with its immutable operation UUID and payments.
  Future<SaleInvoiceDto> postSalesInvoice({
    required Map<String, dynamic> request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/sales/invoices',
      body: request,
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return SaleInvoiceDto.fromJson(json);
  }

  /// Lists sales invoices using an optional UTC date range and cursor.
  Future<List<SaleInvoiceDto>> listSalesInvoices({
    DateTime? from,
    DateTime? to,
    String? cursor,
    int limit = 50,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (from != null) query['from'] = from.toUtc().toIso8601String();
    if (to != null) query['to'] = to.toUtc().toIso8601String();
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final json = await _send('GET', '/v1/sales/invoices', query: query);
    final items = json['items'] as List<dynamic>? ?? json['data'] as List<dynamic>? ?? const [];
    return items
        .map((item) => SaleInvoiceDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Sends between one and one hundred queued operations in one request.
  Future<SyncBatchResponseDto> postSyncBatch({
    required SyncBatchRequestDto request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/sync/batch',
      body: request.toJson(),
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return SyncBatchResponseDto.fromJson(json);
  }

  /// Lists active warehouses in the authenticated branch.
  Future<List<WarehouseDto>> listWarehouses() async {
    final json = await _send('GET', '/v1/inventory/warehouses');
    final items = json['items'] as List<dynamic>? ?? const [];
    return items
        .map((item) => WarehouseDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Lists aisle, shelf and cold-storage locations for one branch warehouse.
  Future<List<AisleShelfDto>> listAisleShelfLocations({
    String? warehouseId,
  }) async {
    final query = <String, String>{};
    if (warehouseId != null && warehouseId.isNotEmpty) {
      query['warehouseId'] = warehouseId;
    }
    final json = await _send(
      'GET',
      '/v1/inventory/locations',
      query: query.isEmpty ? null : query,
    );
    final items = json['items'] as List<dynamic>? ?? const [];
    return items
        .map((item) => AisleShelfDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Lists FEFO batches. The server remains authoritative for branch scope.
  Future<List<ProductBatchFefoDto>> listInventoryBatches({
    String? productId,
    String? warehouseId,
    bool includeInactive = false,
  }) async {
    final query = <String, String>{
      'includeInactive': includeInactive ? 'true' : 'false',
    };
    if (productId != null && productId.isNotEmpty) query['productId'] = productId;
    if (warehouseId != null && warehouseId.isNotEmpty) {
      query['warehouseId'] = warehouseId;
    }
    final json = await _send('GET', '/v1/inventory/batches', query: query);
    final items = json['items'] as List<dynamic>? ?? const [];
    return items
        .map((item) => ProductBatchFefoDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Lists immutable stock movement entries.
  Future<List<StockMovementDto>> listStockMovements({
    String? productId,
    String? warehouseId,
    DateTime? from,
    DateTime? to,
  }) async {
    final query = <String, String>{};
    if (productId != null && productId.isNotEmpty) query['productId'] = productId;
    if (warehouseId != null && warehouseId.isNotEmpty) {
      query['warehouseId'] = warehouseId;
    }
    if (from != null) query['from'] = from.toUtc().toIso8601String();
    if (to != null) query['to'] = to.toUtc().toIso8601String();
    final json = await _send(
      'GET',
      '/v1/inventory/movements',
      query: query.isEmpty ? null : query,
    );
    final items = json['items'] as List<dynamic>? ?? const [];
    return items
        .map((item) => StockMovementDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Creates and posts a purchase invoice. Reuse the same idempotency key on retry.
  Future<PurchaseInvoiceDto> postPurchaseInvoice({
    required Map<String, dynamic> request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/purchases/invoices',
      body: request,
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return PurchaseInvoiceDto.fromJson(json);
  }

  /// Posts a supplier return with a stable idempotency key.
  Future<PurchaseReturnDto> postPurchaseReturn({
    required Map<String, dynamic> request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/purchases/returns',
      body: request,
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return PurchaseReturnDto.fromJson(json);
  }

  /// Loads branch-scoped shortage suggestions from current stock thresholds.
  Future<List<ShortageOrderSuggestionDto>> listShortageSuggestions() async {
    final json = await _send('GET', '/v1/purchases/shortages');
    final items = json['items'] as List<dynamic>? ?? const [];
    return items
        .map((item) => ShortageOrderSuggestionDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Lists stocktaking sessions in the active branch.
  Future<List<StocktakingSessionDto>> listStocktakingSessions() async {
    final json = await _send('GET', '/v1/inventory/stocktaking');
    final items = json['items'] as List<dynamic>? ?? const [];
    return items
        .map((item) => StocktakingSessionDto.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Creates a stocktaking session. Persist and reuse the idempotency key on retry.
  Future<StocktakingSessionDto> createStocktakingSession({
    required Map<String, dynamic> request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/inventory/stocktaking',
      body: request,
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return StocktakingSessionDto.fromJson(json);
  }

  /// Approves a fully counted session after manager authorization.
  Future<StocktakingSessionDto> approveStocktaking({
    required String sessionId,
    required Map<String, dynamic> request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/inventory/stocktaking/\${Uri.encodeComponent(sessionId)}/approve',
      body: request,
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return StocktakingSessionDto.fromJson(json);
  }

  /// Posts an approved disposal report.
  Future<DisposalDto> postDisposal({
    required Map<String, dynamic> request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/inventory/disposals',
      body: request,
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return DisposalDto.fromJson(json);
  }

  /// Executes a transfer between two warehouses belonging to the same branch.
  Future<StockTransferDto> executeStockTransfer({
    required Map<String, dynamic> request,
    required String idempotencyKey,
  }) async {
    _requireIdempotencyKey(idempotencyKey);
    final json = await _send(
      'POST',
      '/v1/inventory/transfers',
      body: request,
      idempotencyKey: idempotencyKey,
      expectedStatuses: const {200, 201},
    );
    return StockTransferDto.fromJson(json);
  }

  /// Sends one HTTP request and decodes a JSON object response.
  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    String? idempotencyKey,
    Set<int> expectedStatuses = const {200},
  }) async {
    final uri = baseUri.resolve(path).replace(queryParameters: query);
    final token = await _accessTokenProvider();
    final branchId = await _branchIdProvider();
    if (branchId == null || branchId.trim().isEmpty) {
      throw StateError('An authenticated branch context is required for API requests.');
    }
    final headers = <String, String>{
      'Accept': 'application/json',
      'X-Branch-Id': branchId,
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };

    late final http.Response response;
    try {
      if (method == 'GET') {
        response = await _http.get(uri, headers: headers).timeout(timeout);
      } else if (method == 'POST') {
        response = await _http
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(timeout);
      } else {
        throw ArgumentError.value(method, 'method', 'Unsupported HTTP method');
      }
    } on Exception {
      rethrow;
    }

    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : _decodeObject(response.body);
    if (!expectedStatuses.contains(response.statusCode)) {
      final error = decoded['error'] is Map<String, dynamic>
          ? decoded['error'] as Map<String, dynamic>
          : decoded;
      throw ApiClientException(
        statusCode: response.statusCode,
        code: error['code'] as String? ?? 'HTTP_${response.statusCode}',
        message: error['message'] as String? ?? 'The API request failed.',
        details: error['details'] is Map<String, dynamic>
            ? error['details'] as Map<String, dynamic>
            : null,
      );
    }
    if (decoded['data'] is Map<String, dynamic>) {
      return decoded['data'] as Map<String, dynamic>;
    }
    return decoded;
  }

  Map<String, dynamic> _decodeObject(String body) {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('Expected a JSON object from the API.');
  }

  void _requireIdempotencyKey(String key) {
    if (key.trim().length < 16 || key.trim().length > 200) {
      throw ArgumentError.value(
        key,
        'idempotencyKey',
        'Must contain between 16 and 200 non-whitespace characters.',
      );
    }
  }
}
