export 'money_amount.dart';
export 'scaled_decimal.dart';

import 'dart:convert';

/// The simplified balance direction returned by the party ledger.
enum BalanceSide { alayh, lah, zero }

/// The supported kinds of parties managed by the branch.
enum PartyType { customer, supplier, employee, partner, representative }

/// The payment methods accepted by POS and voucher workflows.
enum PaymentMethod { cash, wallet, credit, mixed }

/// The electronic wallet providers supported by the application.
enum WalletProvider { jawali, jeeb, floosak, kuraimi }

/// The financial voucher categories supported by the ledger.
enum VoucherType { receipt, payment, adjustment }

/// Converts a JSON string value into a strongly typed enum.
T enumFromJson<T extends Enum>(List<T> values, Object? value, String field) {
  final normalized = value?.toString().toUpperCase();
  for (final item in values) {
    if (item.name.toUpperCase() == normalized) return item;
  }
  throw FormatException('Unknown $field value: $value');
}

/// Converts an enum to the uppercase wire representation.
String enumToJson(Enum value) => value.name.toUpperCase();

/// Shared JSON parsing helpers for nullable values and numeric money strings.
abstract final class ContractJson {
  /// Reads a required string field.
  static String requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing or invalid $key');
    }
    return value;
  }

  /// Reads a decimal field while preserving compatibility with numeric JSON.
  static double decimal(Object? value, {double fallback = 0}) {
    if (value == null) return fallback;
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw FormatException('Invalid decimal value: $value');
  }

  /// Reads a nullable string field.
  static String? nullableString(Object? value) =>
      value?.toString();
}

/// Party information and its balance calculated exclusively from the ledger.
class PartyDto {
  /// Creates a party transfer object.
  const PartyDto({
    required this.id,
    required this.partyType,
    required this.code,
    required this.name,
    required this.totalAlayh,
    required this.totalLah,
    required this.balanceAbs,
    required this.balanceSide,
    this.phone,
    this.address,
    this.creditLimit = 0,
    this.paymentTermsDays = 0,
    this.priceTier = 'RETAIL',
    this.isBlocked = false,
  });

  /// Stable party UUID.
  final String id;

  /// Party category.
  final PartyType partyType;

  /// Branch-unique party code.
  final String code;

  /// Display name.
  final String name;

  /// Optional phone number.
  final String? phone;

  /// Optional postal address.
  final String? address;

  /// Maximum allowed outstanding balance.
  final double creditLimit;

  /// Agreed payment term in days.
  final int paymentTermsDays;

  /// Retail or wholesale pricing tier.
  final String priceTier;

  /// Whether new credit sales are blocked.
  final bool isBlocked;

  /// Sum of ledger movements in the alayh column.
  final double totalAlayh;

  /// Sum of ledger movements in the lah column.
  final double totalLah;

  /// Absolute net balance.
  final double balanceAbs;

  /// Direction of the net balance.
  final BalanceSide balanceSide;

  /// Creates a DTO from the API JSON representation.
  factory PartyDto.fromJson(Map<String, dynamic> json) => PartyDto(
        id: ContractJson.requiredString(json, 'id'),
        partyType: enumFromJson(PartyType.values, json['partyType'], 'partyType'),
        code: ContractJson.requiredString(json, 'code'),
        name: ContractJson.requiredString(json, 'name'),
        phone: ContractJson.nullableString(json['phone']),
        address: ContractJson.nullableString(json['address']),
        creditLimit: ContractJson.decimal(json['creditLimit']),
        paymentTermsDays: (json['paymentTermsDays'] as num?)?.toInt() ?? 0,
        priceTier: json['priceTier'] as String? ?? 'RETAIL',
        isBlocked: json['isBlocked'] as bool? ?? false,
        totalAlayh: ContractJson.decimal(json['totalAlayh']),
        totalLah: ContractJson.decimal(json['totalLah']),
        balanceAbs: ContractJson.decimal(json['balanceAbs']),
        balanceSide: enumFromJson(BalanceSide.values, json['balanceSide'], 'balanceSide'),
      );

  /// Serializes this party without exposing internal accounting journal fields.
  Map<String, dynamic> toJson() => {
        'id': id,
        'partyType': enumToJson(partyType),
        'code': code,
        'name': name,
        'phone': phone,
        'address': address,
        'creditLimit': creditLimit.toStringAsFixed(4),
        'paymentTermsDays': paymentTermsDays,
        'priceTier': priceTier,
        'isBlocked': isBlocked,
        'totalAlayh': totalAlayh.toStringAsFixed(4),
        'totalLah': totalLah.toStringAsFixed(4),
        'balanceAbs': balanceAbs.toStringAsFixed(4),
        'balanceSide': enumToJson(balanceSide),
      };
}

/// One movement in a party statement with its running balance.
class LedgerEntryDto {
  /// Creates a ledger entry DTO.
  const LedgerEntryDto({
    required this.id,
    required this.partyId,
    required this.entryAt,
    required this.entryType,
    required this.alayhAmount,
    required this.lahAmount,
    required this.runningBalance,
    required this.balanceSide,
    this.statement,
    this.documentType,
    this.documentId,
  });

  /// Stable movement UUID.
  final String id;

  /// Related party UUID.
  final String partyId;

  /// Movement timestamp.
  final DateTime entryAt;

  /// Business movement type.
  final String entryType;

  /// Amount increasing the party's alayh total.
  final double alayhAmount;

  /// Amount increasing the party's lah total.
  final double lahAmount;

  /// Running absolute balance after this movement.
  final double runningBalance;

  /// Running balance direction.
  final BalanceSide balanceSide;

  /// Human-readable movement explanation.
  final String? statement;

  /// Source document type.
  final String? documentType;

  /// Source document UUID.
  final String? documentId;

  /// Parses a ledger movement from JSON.
  factory LedgerEntryDto.fromJson(Map<String, dynamic> json) => LedgerEntryDto(
        id: ContractJson.requiredString(json, 'id'),
        partyId: ContractJson.requiredString(json, 'partyId'),
        entryAt: DateTime.parse(ContractJson.requiredString(json, 'entryAt')),
        entryType: ContractJson.requiredString(json, 'entryType'),
        alayhAmount: ContractJson.decimal(json['alayhAmount']),
        lahAmount: ContractJson.decimal(json['lahAmount']),
        runningBalance: ContractJson.decimal(json['runningBalance']),
        balanceSide: enumFromJson(BalanceSide.values, json['balanceSide'], 'balanceSide'),
        statement: ContractJson.nullableString(json['statement']),
        documentType: ContractJson.nullableString(json['documentType']),
        documentId: ContractJson.nullableString(json['documentId']),
      );

  /// Serializes the ledger movement.
  Map<String, dynamic> toJson() => {
        'id': id,
        'partyId': partyId,
        'entryAt': entryAt.toUtc().toIso8601String(),
        'entryType': entryType,
        'alayhAmount': alayhAmount.toStringAsFixed(4),
        'lahAmount': lahAmount.toStringAsFixed(4),
        'runningBalance': runningBalance.toStringAsFixed(4),
        'balanceSide': enumToJson(balanceSide),
        'statement': statement,
        'documentType': documentType,
        'documentId': documentId,
      };
}

/// A party statement and its aggregate ledger balance.
class PartyStatementDto {
  /// Creates a statement response.
  const PartyStatementDto({
    required this.party,
    required this.entries,
    required this.totalAlayh,
    required this.totalLah,
    required this.balanceAbs,
    required this.balanceSide,
    this.nextCursor,
  });

  /// Party header and calculated balance.
  final PartyDto party;

  /// Chronological statement entries.
  final List<LedgerEntryDto> entries;

  /// Aggregate alayh amount.
  final double totalAlayh;

  /// Aggregate lah amount.
  final double totalLah;

  /// Absolute net balance.
  final double balanceAbs;

  /// Net balance direction.
  final BalanceSide balanceSide;

  /// Cursor for the next page.
  final String? nextCursor;

  /// Parses a statement response.
  factory PartyStatementDto.fromJson(Map<String, dynamic> json) => PartyStatementDto(
        party: PartyDto.fromJson(json['party'] as Map<String, dynamic>),
        entries: (json['entries'] as List<dynamic>)
            .map((item) => LedgerEntryDto.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
        totalAlayh: ContractJson.decimal(json['totalAlayh']),
        totalLah: ContractJson.decimal(json['totalLah']),
        balanceAbs: ContractJson.decimal(json['balanceAbs']),
        balanceSide: enumFromJson(BalanceSide.values, json['balanceSide'], 'balanceSide'),
        nextCursor: ContractJson.nullableString(json['nextCursor']),
      );

  /// Serializes a statement response.
  Map<String, dynamic> toJson() => {
        'party': party.toJson(),
        'entries': entries.map((entry) => entry.toJson()).toList(),
        'totalAlayh': totalAlayh.toStringAsFixed(4),
        'totalLah': totalLah.toStringAsFixed(4),
        'balanceAbs': balanceAbs.toStringAsFixed(4),
        'balanceSide': enumToJson(balanceSide),
        'nextCursor': nextCursor,
      };
}

/// Cash drawer or electronic wallet balance.
class CashAccountDto {
  /// Creates a cash account DTO.
  const CashAccountDto({
    required this.id,
    required this.code,
    required this.name,
    required this.accountKind,
    required this.currentBalance,
    required this.currency,
    this.walletProvider,
    this.walletPhone,
  });

  /// Stable account UUID.
  final String id;

  /// Branch-unique account code.
  final String code;

  /// Display label.
  final String name;

  /// CASH_DRAWER, WALLET or BANK.
  final String accountKind;

  /// Current account balance.
  final double currentBalance;

  /// ISO currency code.
  final String currency;

  /// Wallet provider when this is a wallet.
  final WalletProvider? walletProvider;

  /// Optional wallet phone number.
  final String? walletPhone;

  /// Parses a cash account response.
  factory CashAccountDto.fromJson(Map<String, dynamic> json) => CashAccountDto(
        id: ContractJson.requiredString(json, 'id'),
        code: ContractJson.requiredString(json, 'code'),
        name: ContractJson.requiredString(json, 'name'),
        accountKind: ContractJson.requiredString(json, 'accountKind'),
        currentBalance: ContractJson.decimal(json['currentBalance']),
        currency: json['currency'] as String? ?? 'YER',
        walletProvider: json['walletProvider'] == null
            ? null
            : enumFromJson(WalletProvider.values, json['walletProvider'], 'walletProvider'),
        walletPhone: ContractJson.nullableString(json['walletPhone']),
      );

  /// Serializes the cash account.
  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'name': name,
        'accountKind': accountKind,
        'currentBalance': currentBalance.toStringAsFixed(4),
        'currency': currency,
        'walletProvider': walletProvider == null ? null : enumToJson(walletProvider!),
        'walletPhone': walletPhone,
      };
}

/// Receipt, payment or adjustment voucher.
class VoucherDto {
  /// Creates a voucher DTO.
  const VoucherDto({
    required this.id,
    required this.voucherNo,
    required this.voucherType,
    required this.partyId,
    required this.cashAccountId,
    required this.amount,
    required this.method,
    required this.createdAt,
    this.walletProvider,
    this.walletRefNo,
    this.description,
  });

  /// Voucher UUID.
  final String id;

  /// Human-readable voucher number.
  final String voucherNo;

  /// Voucher category.
  final VoucherType voucherType;

  /// Party UUID.
  final String partyId;

  /// Cash account UUID.
  final String cashAccountId;

  /// Voucher amount.
  final double amount;

  /// Payment method.
  final PaymentMethod method;

  /// Creation timestamp.
  final DateTime createdAt;

  /// Wallet provider if applicable.
  final WalletProvider? walletProvider;

  /// Wallet transaction reference.
  final String? walletRefNo;

  /// Voucher explanation.
  final String? description;

  /// Parses a voucher.
  factory VoucherDto.fromJson(Map<String, dynamic> json) => VoucherDto(
        id: ContractJson.requiredString(json, 'id'),
        voucherNo: ContractJson.requiredString(json, 'voucherNo'),
        voucherType: enumFromJson(VoucherType.values, json['voucherType'], 'voucherType'),
        partyId: ContractJson.requiredString(json, 'partyId'),
        cashAccountId: ContractJson.requiredString(json, 'cashAccountId'),
        amount: ContractJson.decimal(json['amount']),
        method: enumFromJson(PaymentMethod.values, json['method'], 'method'),
        createdAt: DateTime.parse(ContractJson.requiredString(json, 'createdAt')),
        walletProvider: json['walletProvider'] == null
            ? null
            : enumFromJson(WalletProvider.values, json['walletProvider'], 'walletProvider'),
        walletRefNo: ContractJson.nullableString(json['walletRefNo']),
        description: ContractJson.nullableString(json['description']),
      );

  /// Serializes the voucher.
  Map<String, dynamic> toJson() => {
        'id': id,
        'voucherNo': voucherNo,
        'voucherType': enumToJson(voucherType),
        'partyId': partyId,
        'cashAccountId': cashAccountId,
        'amount': amount.toStringAsFixed(4),
        'method': enumToJson(method),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'walletProvider': walletProvider == null ? null : enumToJson(walletProvider!),
        'walletRefNo': walletRefNo,
        'description': description,
      };
}

/// One product line on a sales invoice.
class SaleInvoiceItemDto {
  /// Creates a sales invoice item.
  const SaleInvoiceItemDto({
    required this.id,
    required this.productId,
    required this.unitName,
    required this.qtySold,
    required this.conversionFactor,
    required this.qtyBase,
    required this.unitPrice,
    required this.lineTotal,
    this.barcode,
  });

  /// Invoice line UUID.
  final String id;

  /// Product UUID.
  final String productId;

  /// Scanned or selected barcode.
  final String? barcode;

  /// Unit display name.
  final String unitName;

  /// Quantity sold in the selected unit.
  final double qtySold;

  /// Selected unit to base unit conversion factor.
  final double conversionFactor;

  /// Quantity removed from base stock.
  final double qtyBase;

  /// Price per selected unit.
  final double unitPrice;

  /// Extended line total.
  final double lineTotal;

  /// Parses an invoice line.
  factory SaleInvoiceItemDto.fromJson(Map<String, dynamic> json) => SaleInvoiceItemDto(
        id: ContractJson.requiredString(json, 'id'),
        productId: ContractJson.requiredString(json, 'productId'),
        barcode: ContractJson.nullableString(json['barcode']),
        unitName: ContractJson.requiredString(json, 'unitName'),
        qtySold: ContractJson.decimal(json['qtySold']),
        conversionFactor: ContractJson.decimal(json['conversionFactor']),
        qtyBase: ContractJson.decimal(json['qtyBase']),
        unitPrice: ContractJson.decimal(json['unitPrice']),
        lineTotal: ContractJson.decimal(json['lineTotal']),
      );

  /// Serializes an invoice line.
  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'barcode': barcode,
        'unitName': unitName,
        'qtySold': qtySold.toStringAsFixed(4),
        'conversionFactor': conversionFactor.toStringAsFixed(4),
        'qtyBase': qtyBase.toStringAsFixed(4),
        'unitPrice': unitPrice.toStringAsFixed(4),
        'lineTotal': lineTotal.toStringAsFixed(4),
      };
}

/// One cash, wallet or credit payment applied to an invoice.
class SalePaymentDto {
  /// Creates a sale payment.
  const SalePaymentDto({
    required this.id,
    required this.method,
    required this.amount,
    this.cashAccountId,
    this.walletProvider,
    this.walletRefNo,
  });

  /// Payment UUID.
  final String id;

  /// Payment method.
  final PaymentMethod method;

  /// Payment amount.
  final double amount;

  /// Cash account UUID for cash or wallet payments.
  final String? cashAccountId;

  /// Wallet provider.
  final WalletProvider? walletProvider;

  /// Wallet notification/reference number.
  final String? walletRefNo;

  /// Parses a payment.
  factory SalePaymentDto.fromJson(Map<String, dynamic> json) => SalePaymentDto(
        id: ContractJson.requiredString(json, 'id'),
        method: enumFromJson(PaymentMethod.values, json['method'], 'method'),
        amount: ContractJson.decimal(json['amount']),
        cashAccountId: ContractJson.nullableString(json['cashAccountId']),
        walletProvider: json['walletProvider'] == null
            ? null
            : enumFromJson(WalletProvider.values, json['walletProvider'], 'walletProvider'),
        walletRefNo: ContractJson.nullableString(json['walletRefNo']),
      );

  /// Serializes a payment.
  Map<String, dynamic> toJson() => {
        'id': id,
        'method': enumToJson(method),
        'amount': amount.toStringAsFixed(4),
        'cashAccountId': cashAccountId,
        'walletProvider': walletProvider == null ? null : enumToJson(walletProvider!),
        'walletRefNo': walletRefNo,
      };
}

/// Complete sales invoice returned by the API.
class SaleInvoiceDto {
  /// Creates a sale invoice DTO.
  const SaleInvoiceDto({
    required this.id,
    required this.invoiceNo,
    required this.items,
    required this.payments,
    required this.netTotal,
    required this.paidTotal,
    required this.remainingAlayh,
    required this.createdAt,
    required this.priceTier,
    this.customerPartyId,
    this.changeReturned = 0,
  });

  /// Invoice UUID.
  final String id;

  /// Human-readable invoice number.
  final String invoiceNo;

  /// Optional customer UUID.
  final String? customerPartyId;

  /// Applied price tier.
  final String priceTier;

  /// Invoice product lines.
  final List<SaleInvoiceItemDto> items;

  /// Invoice payments.
  final List<SalePaymentDto> payments;

  /// Net invoice total.
  final double netTotal;

  /// Sum of applied payments.
  final double paidTotal;

  /// Change returned to customer.
  final double changeReturned;

  /// Outstanding amount recorded on the customer ledger.
  final double remainingAlayh;

  /// Invoice creation timestamp.
  final DateTime createdAt;

  /// Parses a complete invoice.
  factory SaleInvoiceDto.fromJson(Map<String, dynamic> json) => SaleInvoiceDto(
        id: ContractJson.requiredString(json, 'id'),
        invoiceNo: ContractJson.requiredString(json, 'invoiceNo'),
        customerPartyId: ContractJson.nullableString(json['customerPartyId']),
        priceTier: json['priceTier'] as String? ?? 'RETAIL',
        items: (json['items'] as List<dynamic>)
            .map((item) => SaleInvoiceItemDto.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
        payments: (json['payments'] as List<dynamic>)
            .map((item) => SalePaymentDto.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
        netTotal: ContractJson.decimal(json['netTotal']),
        paidTotal: ContractJson.decimal(json['paidTotal']),
        changeReturned: ContractJson.decimal(json['changeReturned']),
        remainingAlayh: ContractJson.decimal(json['remainingAlayh']),
        createdAt: DateTime.parse(ContractJson.requiredString(json, 'createdAt')),
      );

  /// Serializes the invoice.
  Map<String, dynamic> toJson() => {
        'id': id,
        'invoiceNo': invoiceNo,
        'customerPartyId': customerPartyId,
        'priceTier': priceTier,
        'items': items.map((item) => item.toJson()).toList(),
        'payments': payments.map((payment) => payment.toJson()).toList(),
        'netTotal': netTotal.toStringAsFixed(4),
        'paidTotal': paidTotal.toStringAsFixed(4),
        'changeReturned': changeReturned.toStringAsFixed(4),
        'remainingAlayh': remainingAlayh.toStringAsFixed(4),
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

/// One immutable local operation submitted through batch synchronization.
class SyncOperationDto {
  /// Creates a sync operation.
  const SyncOperationDto({
    required this.operationId,
    required this.operationType,
    required this.payload,
  });

  /// Stable UUID of the logical operation.
  final String operationId;

  /// PARTY_CREATE, SALE_INVOICE or VOUCHER.
  final String operationType;

  /// Operation-specific JSON payload.
  final Map<String, dynamic> payload;

  /// Parses an operation.
  factory SyncOperationDto.fromJson(Map<String, dynamic> json) => SyncOperationDto(
        operationId: ContractJson.requiredString(json, 'operationId'),
        operationType: ContractJson.requiredString(json, 'operationType'),
        payload: Map<String, dynamic>.from(json['payload'] as Map),
      );

  /// Serializes an operation.
  Map<String, dynamic> toJson() => {
        'operationId': operationId,
        'operationType': operationType,
        'payload': payload,
      };
}

/// Request envelope for a batch containing at most 100 operations.
class SyncBatchRequestDto {
  /// Creates a batch request and validates its operation count.
  SyncBatchRequestDto({
    required this.batchId,
    required this.operations,
  }) {
    if (operations.isEmpty || operations.length > 100) {
      throw ArgumentError.value(operations.length, 'operations.length', 'Must be between 1 and 100');
    }
  }

  /// Stable UUID for this batch.
  final String batchId;

  /// Operations to submit atomically.
  final List<SyncOperationDto> operations;

  /// Serializes the batch request.
  Map<String, dynamic> toJson() => {
        'batchId': batchId,
        'operations': operations.map((operation) => operation.toJson()).toList(),
      };

  /// Encodes the batch request as JSON.
  String encode() => jsonEncode(toJson());
}

/// Rejected operation details returned by the server.
class SyncRejectedOperationDto {
  /// Creates a rejected operation response.
  const SyncRejectedOperationDto({
    required this.operationId,
    required this.code,
    required this.message,
  });

  /// Rejected operation UUID.
  final String operationId;

  /// Stable machine-readable error code.
  final String code;

  /// Human-readable reason.
  final String message;

  /// Parses a rejected operation.
  factory SyncRejectedOperationDto.fromJson(Map<String, dynamic> json) =>
      SyncRejectedOperationDto(
        operationId: ContractJson.requiredString(json, 'operationId'),
        code: ContractJson.requiredString(json, 'code'),
        message: ContractJson.requiredString(json, 'message'),
      );

  /// Serializes the rejection.
  Map<String, dynamic> toJson() => {
        'operationId': operationId,
        'code': code,
        'message': message,
      };
}

/// Result of processing a synchronization batch.
class SyncBatchResponseDto {
  /// Creates a batch response.
  const SyncBatchResponseDto({
    required this.batchId,
    required this.acceptedIds,
    required this.rejected,
    required this.serverTime,
    required this.replayed,
  });

  /// Batch UUID.
  final String batchId;

  /// Operation UUIDs accepted by the server.
  final List<String> acceptedIds;

  /// Per-operation rejection details.
  final List<SyncRejectedOperationDto> rejected;

  /// Server processing timestamp.
  final DateTime serverTime;

  /// True when the server returned a previously stored response.
  final bool replayed;

  /// Parses a batch response.
  factory SyncBatchResponseDto.fromJson(Map<String, dynamic> json) =>
      SyncBatchResponseDto(
        batchId: ContractJson.requiredString(json, 'batchId'),
        acceptedIds: (json['acceptedIds'] as List<dynamic>).cast<String>(),
        rejected: (json['rejected'] as List<dynamic>)
            .map((item) => SyncRejectedOperationDto.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
        serverTime: DateTime.parse(ContractJson.requiredString(json, 'serverTime')),
        replayed: json['replayed'] as bool? ?? false,
      );

  /// Serializes the batch response.
  Map<String, dynamic> toJson() => {
        'batchId': batchId,
        'acceptedIds': acceptedIds,
        'rejected': rejected.map((item) => item.toJson()).toList(),
        'serverTime': serverTime.toUtc().toIso8601String(),
        'replayed': replayed,
      };
}
