import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../../ledger/domain/ledger_domain.dart';

/// PostgreSQL implementation of the ledger repository.
class PostgresLedgerRepository implements LedgerRepository {
  /// Creates the repository around an already opened PostgreSQL connection.
  PostgresLedgerRepository(this._connection);

  final PostgreSQLConnection _connection;
  static const Uuid _uuid = Uuid();

  /// Creates a party and stores the idempotent response in the same transaction.
  @override
  Future<Map<String, Object?>> createParty(
    CreatePartyCommand command, {
    required String idempotencyKey,
    required String requestHash,
  }) async {
    return _connection.transaction<Map<String, Object?>>((ctx) async {
      final replay = await _claimIdempotency(ctx, command.branchId, idempotencyKey, requestHash);
      if (replay != null) return replay;

      final id = _uuid.v4();
      await ctx.execute(
        '''INSERT INTO parties
          (id, branch_id, party_type, code, name_ar, phone, address,
           credit_limit, payment_terms_days, price_tier)
          VALUES (@id, @branch, @type, @code, @name, @phone, @address,
                  @limit, @terms, @tier)''',
        substitutionValues: {
          'id': id,
          'branch': command.branchId,
          'type': command.partyType.name.toUpperCase(),
          'code': command.code.trim(),
          'name': command.name.trim(),
          'phone': command.phone,
          'address': command.address,
          'limit': command.creditLimit,
          'terms': command.paymentTermsDays,
          'tier': command.priceTier,
        },
      );
      final rows = await ctx.mappedResultsQuery(
        '''SELECT p.id::text AS id, p.party_type AS "partyType", p.code,
                  p.name_ar AS name, p.phone, p.address,
                  p.credit_limit::text AS "creditLimit",
                  p.payment_terms_days AS "paymentTermsDays",
                  p.price_tier AS "priceTier", p.is_blocked AS "isBlocked",
                  b.total_alayh::text AS "totalAlayh",
                  b.total_lah::text AS "totalLah",
                  b.balance_abs::text AS "balanceAbs",
                  b.balance_side AS "balanceSide"
           FROM parties p JOIN v_party_balance b ON b.party_id = p.id
           WHERE p.id = @id''',
        substitutionValues: {'id': id},
      );
      final result = _flatten(rows.single);
      await _completeIdempotency(ctx, idempotencyKey, 201, result);
      return result;
    });
  }

  /// Lists parties with balance fields sourced only from v_party_balance.
  @override
  Future<List<Map<String, Object?>>> listParties({
    required String branchId,
    String? partyType,
    int limit = 50,
    String? cursor,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT p.id::text AS id, p.party_type AS "partyType", p.code,
                p.name_ar AS name, p.phone, p.address,
                p.credit_limit::text AS "creditLimit",
                p.payment_terms_days AS "paymentTermsDays",
                p.price_tier AS "priceTier", p.is_blocked AS "isBlocked",
                b.total_alayh::text AS "totalAlayh",
                b.total_lah::text AS "totalLah",
                b.balance_abs::text AS "balanceAbs",
                b.balance_side AS "balanceSide"
         FROM parties p
         JOIN v_party_balance b ON b.party_id = p.id
         WHERE p.branch_id = @branch
           AND (@partyType::text IS NULL OR p.party_type = @partyType)
           AND (@cursor::text IS NULL OR p.code > @cursor)
         ORDER BY p.code
         LIMIT @limit''',
      substitutionValues: {
        'branch': branchId,
        'partyType': partyType?.toUpperCase(),
        'cursor': cursor,
        'limit': limit,
      },
    );
    return rows.map(_flatten).toList(growable: false);
  }

  /// Returns statement entries and calculates a running balance from ledger rows.
  @override
  Future<Map<String, Object?>> getPartyStatement({
    required String branchId,
    required String partyId,
    DateTime? from,
    DateTime? to,
    int limit = 100,
    String? cursor,
  }) async {
    final partyRows = await _connection.mappedResultsQuery(
      '''SELECT p.id::text AS id, p.party_type AS "partyType", p.code,
                p.name_ar AS name, p.phone, p.address,
                p.credit_limit::text AS "creditLimit",
                p.payment_terms_days AS "paymentTermsDays",
                p.price_tier AS "priceTier", p.is_blocked AS "isBlocked",
                b.total_alayh::text AS "totalAlayh",
                b.total_lah::text AS "totalLah",
                b.balance_abs::text AS "balanceAbs",
                b.balance_side AS "balanceSide"
         FROM parties p JOIN v_party_balance b ON b.party_id = p.id
         WHERE p.branch_id = @branch AND p.id = @party''',
      substitutionValues: {'branch': branchId, 'party': partyId},
    );
    if (partyRows.isEmpty) throw StateError('Party was not found.');
    final cursorParts = cursor?.split('|');
    final cursorTime = cursorParts == null || cursorParts.isEmpty
        ? null
        : DateTime.parse(cursorParts.first).toUtc();
    final cursorId = cursorParts != null && cursorParts.length > 1
        ? cursorParts[1]
        : '';
    final whereRows = await _connection.mappedResultsQuery(
      '''SELECT * FROM (
           SELECT id::text AS id, entry_date, entry_type AS "entryType",
                  alayh_amount::text AS "alayhAmount", lah_amount::text AS "lahAmount",
                  doc_type AS "documentType", doc_id::text AS "documentId",
                  statement_ar AS statement,
                  SUM(alayh_amount - lah_amount) OVER (
                    ORDER BY entry_date, id
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                  )::text AS "runningNet"
           FROM lah_alayh_ledger
           WHERE branch_id = @branch AND party_id = @party
         ) ledger_rows
         WHERE (@from::timestamptz IS NULL OR entry_date >= @from)
           AND (@to::timestamptz IS NULL OR entry_date <= @to)
           AND (@cursorTime::timestamptz IS NULL OR entry_date > @cursorTime
             OR (entry_date = @cursorTime AND id > @cursorId))
         ORDER BY entry_date, id
         LIMIT @limit''',
      substitutionValues: {
        'branch': branchId,
        'party': partyId,
        'from': from?.toUtc(),
        'to': to?.toUtc(),
        'cursorTime': cursorTime,
        'cursorId': cursorId,
        'limit': limit,
      },
    );

    final entries = <Map<String, Object?>>[];
    for (final row in whereRows) {
      final item = _flatten(row);
      final running = _number(item['runningNet']);
      final entryAt = (item['entry_date'] as DateTime).toUtc().toIso8601String();
      entries.add({
        'id': item['id'],
        'partyId': partyId,
        'entryAt': entryAt,
        'entryType': item['entryType'],
        'alayhAmount': item['alayhAmount'],
        'lahAmount': item['lahAmount'],
        'runningBalance': running.abs().toStringAsFixed(4),
        'balanceSide': running > 0 ? 'ALAYH' : running < 0 ? 'LAH' : 'ZERO',
        'statement': item['statement'],
        'documentType': item['documentType'],
        'documentId': item['documentId'],
      });
    }
    final party = _flatten(partyRows.single);
    return {
      'party': party,
      'entries': entries,
      'totalAlayh': party['totalAlayh'],
      'totalLah': party['totalLah'],
      'balanceAbs': party['balanceAbs'],
      'balanceSide': party['balanceSide'],
      'nextCursor': entries.isEmpty ? null : (entries.last['entryAt'] as String) + '|' + (entries.last['id'] as String),
    };
  }

  /// Posts voucher, cash movement, party movement and journal entry atomically.
  @override
  Future<Map<String, Object?>> postVoucher(PostVoucherCommand command) async {
    return _connection.transaction((ctx) async {
      final replay = await _claimIdempotency(
        ctx, command.branchId, command.idempotencyKey, command.requestHash,
      );
      if (replay != null) return replay;

      final partyRows = await ctx.mappedResultsQuery(
        '''SELECT id::text AS id, party_type AS "partyType"
           FROM parties WHERE id = @party AND branch_id = @branch FOR UPDATE''',
        substitutionValues: {'party': command.partyId, 'branch': command.branchId},
      );
      if (partyRows.isEmpty) throw StateError('Party was not found in this branch.');
      final party = _flatten(partyRows.single);
      final expectedPartyType = command.voucherType == LedgerVoucherType.receipt
          ? 'CUSTOMER'
          : 'SUPPLIER';
      if (party['partyType'] != expectedPartyType) {
        throw StateError('Voucher type does not match the party category.');
      }

      final cashRows = await ctx.mappedResultsQuery(
        '''SELECT id::text AS id, gl_account_id::text AS "glAccountId",
                  current_balance::text AS "currentBalance", account_kind AS "accountKind"
           FROM cash_accounts
           WHERE id = @cash AND branch_id = @branch AND is_active = TRUE
           FOR UPDATE''',
        substitutionValues: {'cash': command.cashAccountId, 'branch': command.branchId},
      );
      if (cashRows.isEmpty) throw StateError('Cash account was not found.');
      final cash = _flatten(cashRows.single);
      final oldBalance = _number(cash['currentBalance']);
      final isReceipt = command.voucherType == LedgerVoucherType.receipt;
      if (!isReceipt && oldBalance < command.amount) {
        throw StateError('Insufficient cash-account balance.');
      }

      final accountRows = await ctx.mappedResultsQuery(
        '''SELECT id::text AS id, code FROM chart_of_accounts
           WHERE branch_id = @branch AND code = @code''',
        substitutionValues: {
          'branch': command.branchId,
          'code': isReceipt ? '1100' : '2000',
        },
      );
      if (accountRows.isEmpty) throw StateError('Required chart account is missing.');
      final counterAccountId = _flatten(accountRows.single)['id'] as String;

      final now = DateTime.now().toUtc();
      final voucherId = _uuid.v4();
      final journalId = _uuid.v4();
      final voucherNo = 'V-${now.microsecondsSinceEpoch}';

      await ctx.execute(
        '''INSERT INTO journal_entries
          (id, branch_id, entry_no, entry_date, doc_type, doc_id, description, status)
          VALUES (@id, @branch, @number, @date, 'VOUCHER', @doc, @description, 'DRAFT')''',
        substitutionValues: {
          'id': journalId,
          'branch': command.branchId,
          'number': voucherNo,
          'date': now,
          'doc': voucherId,
          'description': command.description,
        },
      );

      final cashDr = isReceipt ? command.amount : 0;
      final cashCr = isReceipt ? 0 : command.amount;
      final counterDr = isReceipt ? 0 : command.amount;
      final counterCr = isReceipt ? command.amount : 0;
      await ctx.execute(
        '''INSERT INTO journal_lines
          (journal_entry_id, gl_account_id, dr_amount, cr_amount)
          VALUES (@entry, @cashAccount, @cashDr, @cashCr),
                 (@entry, @counterAccount, @counterDr, @counterCr)''',
        substitutionValues: {
          'entry': journalId,
          'cashAccount': cash['glAccountId'],
          'cashDr': cashDr,
          'cashCr': cashCr,
          'counterAccount': counterAccountId,
          'counterDr': counterDr,
          'counterCr': counterCr,
        },
      );
      await ctx.execute(
        "UPDATE journal_entries SET status = 'POSTED', posted_at = @now WHERE id = @id",
        substitutionValues: {'now': now, 'id': journalId},
      );

      await ctx.execute(
        '''UPDATE cash_accounts SET current_balance = current_balance + @delta,
           updated_at = @now WHERE id = @id''',
        substitutionValues: {
          'delta': isReceipt ? command.amount : -command.amount,
          'now': now,
          'id': command.cashAccountId,
        },
      );

      await ctx.execute(
        '''INSERT INTO vouchers
          (id, branch_id, voucher_no, voucher_type, voucher_date, party_id,
           cash_account_id, amount, method, wallet_ref_no, description,
           journal_entry_id, operation_id)
          VALUES (@id, @branch, @number, @type, @date, @party, @cash,
                  @amount, @method, @walletRef, @description, @journal, @operation)''',
        substitutionValues: {
          'id': voucherId,
          'branch': command.branchId,
          'number': voucherNo,
          'type': command.voucherType.name.toUpperCase(),
          'date': now,
          'party': command.partyId,
          'cash': command.cashAccountId,
          'amount': command.amount,
          'method': command.method,
          'walletRef': command.walletRefNo,
          'description': command.description,
          'journal': journalId,
          'operation': command.operationId,
        },
      );

      await ctx.execute(
        '''INSERT INTO lah_alayh_ledger
          (branch_id, party_id, entry_date, entry_type, alayh_amount, lah_amount,
           doc_type, doc_id, statement_ar, journal_entry_id)
          VALUES (@branch, @party, @date, @type, @alayh, @lah,
                  'VOUCHER', @doc, @statement, @journal)''',
        substitutionValues: {
          'branch': command.branchId,
          'party': command.partyId,
          'date': now,
          'type': isReceipt ? 'RECEIPT' : 'PAYMENT',
          'alayh': isReceipt ? 0 : command.amount,
          'lah': isReceipt ? command.amount : 0,
          'doc': voucherId,
          'statement': command.description,
          'journal': journalId,
        },
      );

      await ctx.execute(
        '''INSERT INTO sync_operation_receipts
          (branch_id, operation_id, operation_type, idempotency_key, result_status)
         VALUES (@branch, @operation, 'VOUCHER', @key, 'ACCEPTED')
         ON CONFLICT (branch_id, operation_id) DO NOTHING''',
        substitutionValues: {
          'branch': command.branchId,
          'operation': command.operationId,
          'key': command.idempotencyKey,
        },
      );

      final result = <String, Object?>{
        'id': voucherId,
        'voucherNo': voucherNo,
        'voucherType': command.voucherType.name.toUpperCase(),
        'partyId': command.partyId,
        'cashAccountId': command.cashAccountId,
        'amount': command.amount.toStringAsFixed(4),
        'method': command.method,
        'createdAt': now.toIso8601String(),
        'walletRefNo': command.walletRefNo,
        'description': command.description,
      };
      await _completeIdempotency(ctx, command.idempotencyKey, 201, result);
      return result;
    });
  }

  /// Lists voucher documents for one branch.
  @override
  Future<List<Map<String, Object?>>> listVouchers({
    required String branchId,
    String? partyId,
    String? voucherType,
    DateTime? from,
    DateTime? to,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT id::text AS id, voucher_no AS "voucherNo",
                voucher_type AS "voucherType", party_id::text AS "partyId",
                cash_account_id::text AS "cashAccountId", amount::text AS amount,
                method, wallet_ref_no AS "walletRefNo", description,
                voucher_date AS "createdAt"
         FROM vouchers WHERE branch_id = @branch
           AND (@party::uuid IS NULL OR party_id = @party)
           AND (@type::text IS NULL OR voucher_type = @type)
           AND (@from::timestamptz IS NULL OR voucher_date >= @from)
           AND (@to::timestamptz IS NULL OR voucher_date <= @to)
         ORDER BY voucher_date DESC LIMIT 500''',
      substitutionValues: {
        'branch': branchId,
        'party': partyId,
        'type': voucherType?.toUpperCase(),
        'from': from?.toUtc(),
        'to': to?.toUtc(),
      },
    );
    return rows.map((row) {
      final item = _flatten(row);
      final date = item['createdAt'];
      item['createdAt'] = date is DateTime ? date.toUtc().toIso8601String() : date.toString();
      return item;
    }).toList(growable: false);
  }

  /// Lists the branch cash drawers and electronic wallets.
  @override
  Future<List<Map<String, Object?>>> listCashAccounts({
    required String branchId,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT id::text AS id, code, name_ar AS name, account_kind AS "accountKind",
                current_balance::text AS "currentBalance", currency,
                wallet_provider AS "walletProvider", wallet_phone AS "walletPhone"
         FROM cash_accounts
         WHERE branch_id = @branch AND is_active = TRUE
         ORDER BY code''',
      substitutionValues: {'branch': branchId},
    );
    return rows.map(_flatten).toList(growable: false);
  }

  Future<Map<String, Object?>?> _claimIdempotency(
    PostgreSQLExecutionContext ctx,
    String branchId,
    String key,
    String requestHash,
  ) async {
    await ctx.execute(
      '''INSERT INTO sync_idempotency (idempotency_key, branch_id, request_hash)
         VALUES (@key, @branch, @hash)
         ON CONFLICT (idempotency_key) DO NOTHING''',
      substitutionValues: {'key': key, 'branch': branchId, 'hash': requestHash},
    );
    final rows = await ctx.mappedResultsQuery(
      '''SELECT branch_id::text AS branchId, request_hash AS requestHash,
                response_body AS responseBody
         FROM sync_idempotency WHERE idempotency_key = @key FOR UPDATE''',
      substitutionValues: {'key': key},
    );
    final record = _flatten(rows.single);
    if (record['branchId'] != branchId || record['requestHash'] != requestHash) {
      throw StateError('IDEMPOTENCY_KEY_REUSED');
    }
    final stored = record['responseBody'];
    if (stored is Map) return Map<String, Object?>.from(stored);
    if (stored is String) {
      final decoded = jsonDecode(stored);
      if (decoded is Map<String, dynamic>) return Map<String, Object?>.from(decoded);
    }
    return null;
  }

  Future<void> _completeIdempotency(
    PostgreSQLExecutionContext ctx,
    String key,
    int status,
    Map<String, Object?> response,
  ) async {
    await ctx.execute(
      '''UPDATE sync_idempotency SET response_status = @status,
         response_body = @body::jsonb, completed_at = now()
         WHERE idempotency_key = @key''',
      substitutionValues: {
        'status': status,
        'body': jsonEncode(response),
        'key': key,
      },
    );
  }

  Map<String, Object?> _flatten(Map<String, Map<String, dynamic>> row) =>
      Map<String, Object?>.from(row.values.first);

  double _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// Calculates a SHA-256 request digest for idempotency storage.
  static String hashRequest(Map<String, Object?> request) =>
      sha256.convert(utf8.encode(jsonEncode(request))).toString();
}
