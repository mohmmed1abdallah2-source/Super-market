/// Domain transfer models for parties, ledger movements, payments, POS tabs and sync quota.
class PartyModel {
  const PartyModel({
    required this.id,
    required this.partyType,
    required this.code,
    required this.nameAr,
    this.phone,
    this.address,
    this.creditLimit = 0,
    this.paymentTermsDays = 0,
    this.priceTier = 'RETAIL',
    this.isBlocked = false,
    this.openingAlayh = 0,
    this.openingLah = 0,
  });

  final String id;
  final String partyType;
  final String code;
  final String nameAr;
  final String? phone;
  final String? address;
  final double creditLimit;
  final int paymentTermsDays;
  final String priceTier;
  final bool isBlocked;
  final double openingAlayh;
  final double openingLah;

  factory PartyModel.fromMap(Map<String, Object?> map) => PartyModel(
    id: map['id'] as String,
    partyType: map['party_type'] as String,
    code: map['code'] as String,
    nameAr: map['name_ar'] as String,
    phone: map['phone'] as String?,
    address: map['address'] as String?,
    creditLimit: (map['credit_limit'] as num? ?? 0).toDouble(),
    paymentTermsDays: (map['payment_terms_days'] as num? ?? 0).toInt(),
    priceTier: map['price_tier'] as String? ?? 'RETAIL',
    isBlocked: (map['is_blocked'] as num? ?? 0) == 1,
    openingAlayh: (map['opening_alayh'] as num? ?? 0).toDouble(),
    openingLah: (map['opening_lah'] as num? ?? 0).toDouble(),
  );
}

/// Represents one movement in the party's simplified balance statement.
class LedgerEntryModel {
  const LedgerEntryModel({
    required this.id,
    required this.partyId,
    required this.entryDate,
    required this.entryType,
    required this.alayhAmount,
    required this.lahAmount,
    this.docType,
    this.docId,
    this.statementAr,
    this.journalEntryId,
  });

  final String id;
  final String partyId;
  final String entryDate;
  final String entryType;
  final double alayhAmount;
  final double lahAmount;
  final String? docType;
  final String? docId;
  final String? statementAr;
  final String? journalEntryId;

  factory LedgerEntryModel.fromMap(Map<String, Object?> map) => LedgerEntryModel(
    id: map['id'] as String,
    partyId: map['party_id'] as String,
    entryDate: map['entry_date'] as String,
    entryType: map['entry_type'] as String,
    alayhAmount: (map['alayh_amount'] as num? ?? 0).toDouble(),
    lahAmount: (map['lah_amount'] as num? ?? 0).toDouble(),
    docType: map['doc_type'] as String?,
    docId: map['doc_id'] as String?,
    statementAr: map['statement_ar'] as String?,
    journalEntryId: map['journal_entry_id'] as String?,
  );
}

/// Describes a cash drawer, bank account or electronic wallet.
class CashAccountModel {
  const CashAccountModel({
    required this.id,
    required this.code,
    required this.nameAr,
    required this.accountKind,
    this.walletProvider,
    this.walletPhone,
    this.glAccountId,
    this.currentBalance = 0,
  });

  final String id;
  final String code;
  final String nameAr;
  final String accountKind;
  final String? walletProvider;
  final String? walletPhone;
  final String? glAccountId;
  final double currentBalance;
}

/// Represents a receipt, payment or settlement voucher.
class VoucherModel {
  const VoucherModel({
    required this.id,
    required this.voucherNo,
    required this.voucherType,
    required this.voucherDate,
    this.partyId,
    this.cashAccountId,
    required this.amount,
    required this.method,
    this.walletRefNo,
    this.description,
    this.journalEntryId,
  });

  final String id;
  final String voucherNo;
  final String voucherType;
  final String voucherDate;
  final String? partyId;
  final String? cashAccountId;
  final double amount;
  final String method;
  final String? walletRefNo;
  final String? description;
  final String? journalEntryId;
}

/// One editable line in an open POS tab; stock is not changed until posting.
class PosCartItemModel {
  const PosCartItemModel({
    required this.productId,
    required this.unitId,
    required this.productName,
    required this.unitName,
    required this.conversionFactor,
    required this.quantity,
    required this.unitPrice,
    this.lineDiscountAmount = 0,
    this.unitCost = 0,
  });

  final String productId;
  final String unitId;
  final String productName;
  final String unitName;
  final double conversionFactor;
  final double quantity;
  final double unitPrice;
  final double lineDiscountAmount;
  final double unitCost;

  double get baseQuantity => quantity * conversionFactor;
  double get lineTotal => quantity * unitPrice - lineDiscountAmount;

  PosCartItemModel copyWith({
    double? quantity,
    double? unitPrice,
    double? lineDiscountAmount,
    String? unitId,
    String? unitName,
    double? conversionFactor,
  }) => PosCartItemModel(
    productId: productId,
    unitId: unitId ?? this.unitId,
    productName: productName,
    unitName: unitName ?? this.unitName,
    conversionFactor: conversionFactor ?? this.conversionFactor,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice ?? this.unitPrice,
    lineDiscountAmount: lineDiscountAmount ?? this.lineDiscountAmount,
    unitCost: unitCost,
  );
}

/// Holds an independent customer invoice tab in the cashier workspace.
class PosTabSession {
  PosTabSession({
    required this.id,
    this.label = '',
    this.priceTier = 'RETAIL',
    this.customerPartyId,
    List<PosCartItemModel>? items,
    this.isHeld = false,
  }) : items = items ?? <PosCartItemModel>[];

  final String id;
  String label;
  String priceTier;
  String? customerPartyId;
  final List<PosCartItemModel> items;
  bool isHeld;

  double get subtotal => items.fold(0, (sum, item) => sum + item.lineTotal);
}

/// Summary returned after a sale is durably committed to local storage.
class SaleInvoiceModel {
  const SaleInvoiceModel({
    required this.id,
    required this.invoiceNo,
    required this.netTotal,
    required this.paidTotal,
    required this.changeReturned,
    required this.remainingAlayh,
  });

  final String id;
  final String invoiceNo;
  final double netTotal;
  final double paidTotal;
  final double changeReturned;
  final double remainingAlayh;
}

/// Local estimate of daily cloud quota consumption.
class FirebaseQuotaModel {
  const FirebaseQuotaModel({
    required this.dateKey,
    this.writesUsed = 0,
    this.readsUsed = 0,
    this.deletesUsed = 0,
    this.maxDailyWritesLimit = 18000,
  });

  final String dateKey;
  final int writesUsed;
  final int readsUsed;
  final int deletesUsed;
  final int maxDailyWritesLimit;

  double get writeUsageRatio =>
      maxDailyWritesLimit <= 0 ? 1 : writesUsed / maxDailyWritesLimit;
}