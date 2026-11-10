import '../domain/sales_sync_domain.dart';

/// Validates and posts one invoice.
class PostSaleInvoiceUseCase {
  /// Creates the use case.
  const PostSaleInvoiceUseCase(this._repository);

  final SalesSyncRepository _repository;

  /// Executes the sale posting command.
  Future<Map<String, Object?>> call(SaleInvoiceCommand command) {
    final items = command.request['items'];
    final payments = command.request['payments'];
    if (items is! List || items.isEmpty) {
      throw const FormatException('A sale must contain at least one item.');
    }
    if (payments is! List) {
      throw const FormatException('Sale payments must be a list.');
    }
    if (command.idempotencyKey.trim().length < 16) {
      throw const FormatException('A valid Idempotency-Key is required.');
    }
    return _repository.postSale(command);
  }
}

/// Processes up to one hundred offline operations in one database transaction.
class ProcessSyncBatchUseCase {
  /// Creates the use case.
  const ProcessSyncBatchUseCase(this._repository);

  final SalesSyncRepository _repository;

  /// Executes a batch after validating its envelope and operation identifiers.
  Future<Map<String, Object?>> call(SyncBatchCommand command) {
    if (command.operations.isEmpty || command.operations.length > 100) {
      throw RangeError.range(command.operations.length, 1, 100, 'operations.length');
    }
    if (command.idempotencyKey.trim().length < 16) {
      throw const FormatException('A valid Idempotency-Key is required.');
    }
    final ids = command.operations.map((item) => item.operationId).toSet();
    if (ids.length != command.operations.length) {
      throw const FormatException('A batch cannot contain duplicate operation IDs.');
    }
    const allowed = {'PARTY_CREATE', 'SALE_INVOICE', 'VOUCHER'};
    for (final operation in command.operations) {
      if (!allowed.contains(operation.operationType)) {
        throw FormatException('Unsupported operation type: ${operation.operationType}');
      }
    }
    return _repository.processBatch(command);
  }
}

/// Lists branch sales invoices with their line items and payment allocations.
class ListSalesInvoicesUseCase {
  /// Creates the use case.
  const ListSalesInvoicesUseCase(this._repository);

  final SalesSyncRepository _repository;

  /// Executes a paginated invoice query.
  Future<List<Map<String, Object?>>> call({
    required String branchId,
    DateTime? from,
    DateTime? to,
    String? cursor,
    int limit = 50,
  }) {
    if (limit < 1 || limit > 100) {
      throw RangeError.range(limit, 1, 100, 'limit');
    }
    if (from != null && to != null && from.isAfter(to)) {
      throw const FormatException('Start date must not exceed end date.');
    }
    return _repository.listSalesInvoices(
      branchId: branchId,
      from: from,
      to: to,
      cursor: cursor,
      limit: limit,
    );
  }
}
