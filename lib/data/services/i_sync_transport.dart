/// Provider-neutral contract for writing branch synchronization data to a remote store.
abstract class ISyncTransport {
  /// Persists one idempotently identified compressed batch document.
  Future<void> putBatch({
    required String branchId,
    required String batchId,
    required Map<String, Object?> data,
  });

  /// Updates the branch's daily dashboard summary document.
  Future<void> putDailySummary({
    required String documentId,
    required Map<String, Object?> data,
  });
}