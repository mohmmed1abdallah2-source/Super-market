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
