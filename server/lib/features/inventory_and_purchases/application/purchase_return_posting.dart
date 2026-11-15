/// Immutable command for posting a supplier return against a posted purchase invoice.
final class PurchaseReturnCommand {
  const PurchaseReturnCommand({
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

abstract interface class PurchaseReturnPostingRepository {
  Future<Map<String, Object?>> postPurchaseReturn(PurchaseReturnCommand command);
}

final class PostPurchaseReturnUseCase {
  const PostPurchaseReturnUseCase(this._repository);

  final PurchaseReturnPostingRepository _repository;

  Future<Map<String, Object?>> call(PurchaseReturnCommand command) {
    final items = command.request['items'];
    if (items is! List || items.isEmpty) {
      throw const FormatException('A purchase return must contain at least one item.');
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
        throw const FormatException('Every purchase return item must be a JSON object.');
      }
    }
    return _repository.postPurchaseReturn(command);
  }
}
