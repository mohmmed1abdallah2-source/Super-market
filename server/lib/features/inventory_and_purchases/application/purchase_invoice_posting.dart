/// Immutable command for posting one supplier purchase invoice.
final class PurchaseInvoiceCommand {
  const PurchaseInvoiceCommand({
    required this.branchId,
    required this.operationId,
    required this.idempotencyKey,
    required this.requestHash,
    required this.request,
  });

  final String branchId;
  final String operationId;
  final String idempotencyKey;
  final String requestHash;
  final Map<String, dynamic> request;
}

/// Application boundary for transactional purchase invoice posting.
abstract interface class PurchaseInvoicePostingRepository {
  Future<Map<String, Object?>> postPurchaseInvoice(PurchaseInvoiceCommand command);
}

/// Validates the purchase envelope before the persistence transaction.
final class PostPurchaseInvoiceUseCase {
  const PostPurchaseInvoiceUseCase(this._repository);

  final PurchaseInvoicePostingRepository _repository;

  Future<Map<String, Object?>> call(PurchaseInvoiceCommand command) {
    final items = command.request['items'];
    if (items is! List || items.isEmpty) {
      throw const FormatException('A purchase invoice must contain at least one item.');
    }
    if (command.operationId.trim().isEmpty) {
      throw const FormatException('operationId is required.');
    }
    if (command.idempotencyKey.trim().length < 16 ||
        command.idempotencyKey.length > 200) {
      throw const FormatException('A valid Idempotency-Key is required.');
    }
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Every purchase item must be a JSON object.');
      }
    }
    return _repository.postPurchaseInvoice(command);
  }
}
