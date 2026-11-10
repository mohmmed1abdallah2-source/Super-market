/// Domain types and repository boundary for sales and offline batch sync.

/// A validated request to post one sale invoice.
class SaleInvoiceCommand {
  /// Creates a sale command.
  const SaleInvoiceCommand({
    required this.branchId,
    required this.operationId,
    required this.request,
    required this.idempotencyKey,
    required this.requestHash,
  });

  /// Authenticated branch UUID.
  final String branchId;

  /// Stable UUID assigned by the originating client.
  final String operationId;

  /// Immutable invoice request body.
  final Map<String, dynamic> request;

  /// HTTP idempotency key.
  final String idempotencyKey;

  /// Canonical request SHA-256 digest.
  final String requestHash;
}

/// One immutable operation in an offline synchronization batch.
class SyncOperation {
  /// Creates a sync operation.
  const SyncOperation({
    required this.operationId,
    required this.operationType,
    required this.payload,
  });

  /// Stable operation UUID.
  final String operationId;

  /// PARTY_CREATE, SALE_INVOICE or VOUCHER.
  final String operationType;

  /// Operation-specific data.
  final Map<String, dynamic> payload;
}

/// Batch synchronization command.
class SyncBatchCommand {
  /// Creates a batch command.
  const SyncBatchCommand({
    required this.branchId,
    required this.batchId,
    required this.idempotencyKey,
    required this.requestHash,
    required this.operations,
  });

  /// Authenticated branch UUID.
  final String branchId;

  /// Stable batch UUID.
  final String batchId;

  /// HTTP idempotency key.
  final String idempotencyKey;

  /// Canonical request SHA-256 digest.
  final String requestHash;

  /// One to one hundred operations.
  final List<SyncOperation> operations;
}

/// Repository contract for sale posting and batch processing.
abstract interface class SalesSyncRepository {
  /// Posts one sale atomically and returns the stored invoice representation.
  Future<Map<String, Object?>> postSale(SaleInvoiceCommand command);

  /// Lists sales invoices for the authenticated branch.
  Future<List<Map<String, Object?>>> listSalesInvoices({
    required String branchId,
    DateTime? from,
    DateTime? to,
    String? cursor,
    int limit,
  });

  /// Applies a batch atomically and returns accepted operation identifiers.
  Future<Map<String, Object?>> processBatch(SyncBatchCommand command);
}
