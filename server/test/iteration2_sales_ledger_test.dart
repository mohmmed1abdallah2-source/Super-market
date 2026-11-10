import 'package:test/test.dart';

import '../lib/features/ledger/application/ledger_use_cases.dart';
import '../lib/features/ledger/domain/ledger_domain.dart';
import '../lib/features/sales_and_sync/application/sales_sync_use_cases.dart';
import '../lib/features/sales_and_sync/domain/sales_sync_domain.dart';

void main() {
  group('Iteration 2 ledger validation', () {
    test('wallet voucher requires a six-character notification reference', () async {
      final useCase = PostVoucherUseCase(_FakeLedgerRepository());
      final command = PostVoucherCommand(
        branchId: 'branch-main',
        operationId: 'operation-00000001',
        voucherType: LedgerVoucherType.receipt,
        partyId: 'customer-1',
        cashAccountId: 'wallet-jawali',
        amount: 10,
        method: 'WALLET',
        idempotencyKey: 'idempotency-key-0001',
        requestHash: List.filled(64, '0').join(),
        walletRefNo: '12345',
      );
      expect(() => useCase(command), throwsFormatException);
    });

    test('voucher amount must be positive', () async {
      final useCase = PostVoucherUseCase(_FakeLedgerRepository());
      final command = PostVoucherCommand(
        branchId: 'branch-main',
        operationId: 'operation-00000002',
        voucherType: LedgerVoucherType.receipt,
        partyId: 'customer-1',
        cashAccountId: 'cash-drawer',
        amount: 0,
        method: 'CASH',
        idempotencyKey: 'idempotency-key-0002',
        requestHash: List.filled(64, '1').join(),
      );
      expect(() => useCase(command), throwsFormatException);
    });
  });

  group('Iteration 2 sales and sync validation', () {
    test('sale requires at least one invoice item', () async {
      final useCase = PostSaleInvoiceUseCase(_FakeSalesSyncRepository());
      final command = SaleInvoiceCommand(
        branchId: 'branch-main',
        operationId: 'operation-00000003',
        request: {'items': <Object>[], 'payments': <Object>[]},
        idempotencyKey: 'idempotency-key-0003',
        requestHash: List.filled(64, '2').join(),
      );
      expect(() => useCase(command), throwsFormatException);
    });

    test('sync batch is limited to one hundred operations', () async {
      final operations = List.generate(
        101,
        (index) => SyncOperation(
          operationId: 'operation-$index',
          operationType: 'PARTY_CREATE',
          payload: const {},
        ),
      );
      final useCase = ProcessSyncBatchUseCase(_FakeSalesSyncRepository());
      final command = SyncBatchCommand(
        branchId: 'branch-main',
        batchId: 'batch-0000000001',
        idempotencyKey: 'idempotency-key-0004',
        requestHash: List.filled(64, '3').join(),
        operations: operations,
      );
      expect(() => useCase(command), throwsRangeError);
    });

    test('duplicate operation UUIDs are rejected before persistence', () async {
      final operation = SyncOperation(
        operationId: 'operation-duplicate',
        operationType: 'PARTY_CREATE',
        payload: const {},
      );
      final useCase = ProcessSyncBatchUseCase(_FakeSalesSyncRepository());
      final command = SyncBatchCommand(
        branchId: 'branch-main',
        batchId: 'batch-0000000002',
        idempotencyKey: 'idempotency-key-0005',
        requestHash: List.filled(64, '4').join(),
        operations: [operation, operation],
      );
      expect(() => useCase(command), throwsFormatException);
    });
  });
}

class _FakeLedgerRepository implements LedgerRepository {
  @override
  Future<Map<String, Object?>> createParty(CreatePartyCommand command,
      {required String idempotencyKey, required String requestHash}) async => {};

  @override
  Future<Map<String, Object?>> getPartyStatement({
    required String branchId,
    required String partyId,
    DateTime? from,
    DateTime? to,
    int limit = 100,
    String? cursor,
  }) async => {};

  @override
  Future<List<Map<String, Object?>>> listCashAccounts({required String branchId}) async => [];

  @override
  Future<List<Map<String, Object?>>> listParties({
    required String branchId,
    String? partyType,
    int limit = 50,
    String? cursor,
  }) async => [];

  @override
  Future<List<Map<String, Object?>>> listVouchers({
    required String branchId,
    String? partyId,
    String? voucherType,
    DateTime? from,
    DateTime? to,
  }) async => [];

  @override
  Future<Map<String, Object?>> postVoucher(PostVoucherCommand command) async => {};
}

class _FakeSalesSyncRepository implements SalesSyncRepository {
  @override
  Future<Map<String, Object?>> postSale(SaleInvoiceCommand command) async => {};

  @override
  Future<List<Map<String, Object?>>> listSalesInvoices({
    required String branchId,
    DateTime? from,
    DateTime? to,
    String? cursor,
    int limit = 50,
  }) async => [];

  @override
  Future<Map<String, Object?>> processBatch(SyncBatchCommand command) async => {};
}
