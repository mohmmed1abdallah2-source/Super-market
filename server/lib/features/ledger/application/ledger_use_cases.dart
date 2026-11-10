import '../domain/ledger_domain.dart';

/// Validates and creates a party using the ledger repository.
class CreatePartyUseCase {
  /// Creates the use case.
  const CreatePartyUseCase(this._repository);

  final LedgerRepository _repository;

  /// Executes party creation.
  Future<Map<String, Object?>> call({
    required CreatePartyCommand command,
    required String idempotencyKey,
    required String requestHash,
  }) {
    if (command.code.trim().isEmpty || command.name.trim().isEmpty) {
      throw const FormatException('Party code and name are required.');
    }
    if (command.creditLimit < 0 || command.paymentTermsDays < 0) {
      throw const FormatException('Credit limit and payment terms cannot be negative.');
    }
    if (!const {'RETAIL', 'WHOLESALE'}.contains(command.priceTier)) {
      throw const FormatException('Unsupported price tier.');
    }
    return _repository.createParty(
      command,
      idempotencyKey: idempotencyKey,
      requestHash: requestHash,
    );
  }
}

/// Lists parties and obtains their balances from the ledger view.
class ListPartiesWithBalanceUseCase {
  /// Creates the use case.
  const ListPartiesWithBalanceUseCase(this._repository);

  final LedgerRepository _repository;

  /// Executes a paginated party query.
  Future<List<Map<String, Object?>>> call({
    required String branchId,
    String? partyType,
    int limit = 50,
    String? cursor,
  }) {
    if (limit < 1 || limit > 100) {
      throw RangeError.range(limit, 1, 100, 'limit');
    }
    return _repository.listParties(
      branchId: branchId,
      partyType: partyType,
      limit: limit,
      cursor: cursor,
    );
  }
}

/// Retrieves a party statement with its ledger-derived totals.
class GetPartyStatementUseCase {
  /// Creates the use case.
  const GetPartyStatementUseCase(this._repository);

  final LedgerRepository _repository;

  /// Executes a statement query.
  Future<Map<String, Object?>> call({
    required String branchId,
    required String partyId,
    DateTime? from,
    DateTime? to,
    int limit = 100,
    String? cursor,
  }) {
    if (limit < 1 || limit > 500) {
      throw RangeError.range(limit, 1, 500, 'limit');
    }
    if (from != null && to != null && from.isAfter(to)) {
      throw const FormatException('Statement start date must not exceed end date.');
    }
    return _repository.getPartyStatement(
      branchId: branchId,
      partyId: partyId,
      from: from,
      to: to,
      limit: limit,
      cursor: cursor,
    );
  }
}

/// Validates and posts a voucher with atomic ledger and cash effects.
class PostVoucherUseCase {
  /// Creates the use case.
  const PostVoucherUseCase(this._repository);

  final LedgerRepository _repository;

  /// Executes voucher posting.
  Future<Map<String, Object?>> call(PostVoucherCommand command) {
    if (command.amount <= 0) {
      throw const FormatException('Voucher amount must be greater than zero.');
    }
    if (!const {'CASH', 'WALLET'}.contains(command.method)) {
      throw const FormatException('Voucher method must be CASH or WALLET.');
    }
    if (command.method == 'WALLET' &&
        (command.walletRefNo == null || command.walletRefNo!.trim().length < 6)) {
      throw const FormatException('Wallet notification reference must contain at least 6 characters.');
    }
    if (command.idempotencyKey.trim().length < 16) {
      throw const FormatException('A valid Idempotency-Key is required.');
    }
    return _repository.postVoucher(command);
  }
}

/// Lists the branch voucher history.
class ListVouchersUseCase {
  /// Creates the use case.
  const ListVouchersUseCase(this._repository);

  final LedgerRepository _repository;

  /// Executes a voucher list query.
  Future<List<Map<String, Object?>>> call({
    required String branchId,
    String? partyId,
    String? voucherType,
    DateTime? from,
    DateTime? to,
  }) =>
      _repository.listVouchers(
        branchId: branchId,
        partyId: partyId,
        voucherType: voucherType,
        from: from,
        to: to,
      );
}

/// Lists cash drawers and wallets available to the branch.
class ListCashAccountsUseCase {
  /// Creates the use case.
  const ListCashAccountsUseCase(this._repository);

  final LedgerRepository _repository;

  /// Executes the cash-account query.
  Future<List<Map<String, Object?>>> call(String branchId) =>
      _repository.listCashAccounts(branchId: branchId);
}
