import 'money_amount.dart';
import 'scaled_decimal.dart';

/// Strict JSON helpers for Iteration 3 decimal contracts.
/// Monetary and measured values travel as decimal strings, never JSON doubles.
abstract final class InventoryContractJson {
  static String text(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing or invalid $key');
    }
    return value;
  }

  static String? nullableText(Object? value) =>
      value == null ? null : value is String ? value : throw FormatException('Invalid text value');

  static int integer(Map<String, dynamic> json, String key, {int fallback = 0}) {
    final value = json[key];
    if (value == null) return fallback;
    if (value is int) return value;
    throw FormatException('$key must be an integer');
  }

  static bool boolean(Map<String, dynamic> json, String key, {bool fallback = false}) {
    final value = json[key];
    if (value == null) return fallback;
    if (value is bool) return value;
    throw FormatException('$key must be a boolean');
  }

  static DateTime date(Map<String, dynamic> json, String key) =>
      DateTime.parse(text(json, key));

  static MoneyAmount money(Map<String, dynamic> json, String key) =>
      MoneyAmount.fromString(decimalText(json[key], key));

  static ScaledDecimal decimal(
    Map<String, dynamic> json,
    String key, {
    required int scale,
  }) => ScaledDecimal.fromString(decimalText(json[key], key), scale: scale);

  static String decimalText(Object? value, String key) {
    if (value is String) return value;
    if (value is int) return value.toString();
    throw FormatException('$key must be sent as a decimal string (or integer), not a floating-point number');
  }
}

/// Warehouse owned by one operating branch.
final class WarehouseDto {
  const WarehouseDto({
    required this.id,
    required this.code,
    required this.name,
    required this.warehouseType,
    required this.isSellable,
    required this.isActive,
  });

  final String id;
  final String code;
  final String name;
  final String warehouseType;
  final bool isSellable;
  final bool isActive;

  factory WarehouseDto.fromJson(Map<String, dynamic> json) => WarehouseDto(
        id: InventoryContractJson.text(json, 'id'),
        code: InventoryContractJson.text(json, 'code'),
        name: InventoryContractJson.text(json, 'name'),
        warehouseType: InventoryContractJson.text(json, 'warehouseType'),
        isSellable: InventoryContractJson.boolean(json, 'isSellable'),
        isActive: InventoryContractJson.boolean(json, 'isActive'),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'name': name,
        'warehouseType': warehouseType,
        'isSellable': isSellable,
        'isActive': isActive,
      };
}

/// Aisle, shelf, fridge or display location inside a branch warehouse.
final class AisleShelfDto {
  const AisleShelfDto({
    required this.id,
    required this.warehouseId,
    required this.code,
    required this.name,
    required this.locationType,
    required this.isActive,
  });

  final String id;
  final String warehouseId;
  final String code;
  final String name;
  final String locationType;
  final bool isActive;

  factory AisleShelfDto.fromJson(Map<String, dynamic> json) => AisleShelfDto(
        id: InventoryContractJson.text(json, 'id'),
        warehouseId: InventoryContractJson.text(json, 'warehouseId'),
        code: InventoryContractJson.text(json, 'code'),
        name: InventoryContractJson.text(json, 'name'),
        locationType: InventoryContractJson.text(json, 'locationType'),
        isActive: InventoryContractJson.boolean(json, 'isActive'),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'warehouseId': warehouseId,
        'code': code,
        'name': name,
        'locationType': locationType,
        'isActive': isActive,
      };
}

/// FEFO batch balance. Quantities and costs preserve the database scales.
final class ProductBatchFefoDto {
  const ProductBatchFefoDto({
    required this.id,
    required this.productId,
    required this.warehouseId,
    required this.batchNo,
    required this.expiryDate,
    required this.packConversionFactor,
    required this.sealedCartons,
    required this.looseBaseQty,
    required this.totalBaseQty,
    required this.unitCostBase,
    required this.status,
    this.locationId,
  });

  final String id;
  final String productId;
  final String warehouseId;
  final String? locationId;
  final String batchNo;
  final DateTime expiryDate;
  final ScaledDecimal packConversionFactor;
  final int sealedCartons;
  final ScaledDecimal looseBaseQty;
  final ScaledDecimal totalBaseQty;
  final ScaledDecimal unitCostBase;
  final String status;

  factory ProductBatchFefoDto.fromJson(Map<String, dynamic> json) => ProductBatchFefoDto(
        id: InventoryContractJson.text(json, 'id'),
        productId: InventoryContractJson.text(json, 'productId'),
        warehouseId: InventoryContractJson.text(json, 'warehouseId'),
        locationId: InventoryContractJson.nullableText(json['locationId']),
        batchNo: InventoryContractJson.text(json, 'batchNo'),
        expiryDate: InventoryContractJson.date(json, 'expiryDate'),
        packConversionFactor: InventoryContractJson.decimal(json, 'packConversionFactor', scale: 6),
        sealedCartons: InventoryContractJson.integer(json, 'sealedCartons'),
        looseBaseQty: InventoryContractJson.decimal(json, 'looseBaseQty', scale: 6),
        totalBaseQty: InventoryContractJson.decimal(json, 'totalBaseQty', scale: 6),
        unitCostBase: InventoryContractJson.decimal(json, 'unitCostBase', scale: 6),
        status: InventoryContractJson.text(json, 'status'),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'warehouseId': warehouseId,
        'locationId': locationId,
        'batchNo': batchNo,
        'expiryDate': expiryDate.toIso8601String().split('T').first,
        'packConversionFactor': packConversionFactor.toFixedString(),
        'sealedCartons': sealedCartons,
        'looseBaseQty': looseBaseQty.toFixedString(),
        'totalBaseQty': totalBaseQty.toFixedString(),
        'unitCostBase': unitCostBase.toFixedString(),
        'status': status,
      };
}

/// Append-only stock movement entry.
final class StockMovementDto {
  const StockMovementDto({
    required this.id,
    required this.productId,
    required this.movementType,
    required this.movementDate,
    required this.quantityBase,
    required this.unitCostBase,
    required this.documentType,
    required this.documentId,
    this.warehouseId,
    this.productBatchId,
    this.referenceNo,
    this.notes = '',
  });

  final String id;
  final String productId;
  final String? warehouseId;
  final String? productBatchId;
  final String movementType;
  final DateTime movementDate;
  final ScaledDecimal quantityBase;
  final ScaledDecimal unitCostBase;
  final String documentType;
  final String documentId;
  final String? referenceNo;
  final String notes;

  factory StockMovementDto.fromJson(Map<String, dynamic> json) => StockMovementDto(
        id: InventoryContractJson.text(json, 'id'),
        productId: InventoryContractJson.text(json, 'productId'),
        warehouseId: InventoryContractJson.nullableText(json['warehouseId']),
        productBatchId: InventoryContractJson.nullableText(json['productBatchId']),
        movementType: InventoryContractJson.text(json, 'movementType'),
        movementDate: InventoryContractJson.date(json, 'movementDate'),
        quantityBase: InventoryContractJson.decimal(json, 'quantityBase', scale: 6),
        unitCostBase: InventoryContractJson.decimal(json, 'unitCostBase', scale: 6),
        documentType: InventoryContractJson.text(json, 'documentType'),
        documentId: InventoryContractJson.text(json, 'documentId'),
        referenceNo: InventoryContractJson.nullableText(json['referenceNo']),
        notes: json['notes'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'warehouseId': warehouseId,
        'productBatchId': productBatchId,
        'movementType': movementType,
        'movementDate': movementDate.toUtc().toIso8601String(),
        'quantityBase': quantityBase.toFixedString(),
        'unitCostBase': unitCostBase.toFixedString(),
        'documentType': documentType,
        'documentId': documentId,
        'referenceNo': referenceNo,
        'notes': notes,
      };
}

/// Stocktaking session header and approval state.
final class StocktakingSessionDto {
  const StocktakingSessionDto({
    required this.id,
    required this.warehouseId,
    required this.sessionNo,
    required this.status,
    required this.blindCount,
    required this.startedAt,
    this.completedAt,
    this.approvedAt,
  });

  final String id;
  final String warehouseId;
  final String sessionNo;
  final String status;
  final bool blindCount;
  final DateTime startedAt;
  final DateTime? completedAt;
  final DateTime? approvedAt;

  factory StocktakingSessionDto.fromJson(Map<String, dynamic> json) => StocktakingSessionDto(
        id: InventoryContractJson.text(json, 'id'),
        warehouseId: InventoryContractJson.text(json, 'warehouseId'),
        sessionNo: InventoryContractJson.text(json, 'sessionNo'),
        status: InventoryContractJson.text(json, 'status'),
        blindCount: InventoryContractJson.boolean(json, 'blindCount'),
        startedAt: InventoryContractJson.date(json, 'startedAt'),
        completedAt: json['completedAt'] == null ? null : DateTime.parse(json['completedAt'] as String),
        approvedAt: json['approvedAt'] == null ? null : DateTime.parse(json['approvedAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'warehouseId': warehouseId,
        'sessionNo': sessionNo,
        'status': status,
        'blindCount': blindCount,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'completedAt': completedAt?.toUtc().toIso8601String(),
        'approvedAt': approvedAt?.toUtc().toIso8601String(),
      };
}

/// Counted quantity for one product or FEFO batch in a stocktake.
final class StocktakingLineDto {
  const StocktakingLineDto({
    required this.id,
    required this.productId,
    required this.expectedBaseQty,
    required this.countedSealedCartons,
    required this.countedLooseBaseQty,
    required this.packConversionFactor,
    required this.countedBaseQty,
    required this.varianceBaseQty,
    this.productBatchId,
  });

  final String id;
  final String productId;
  final String? productBatchId;
  final ScaledDecimal expectedBaseQty;
  final int countedSealedCartons;
  final ScaledDecimal countedLooseBaseQty;
  final ScaledDecimal packConversionFactor;
  final ScaledDecimal countedBaseQty;
  final ScaledDecimal varianceBaseQty;

  factory StocktakingLineDto.fromJson(Map<String, dynamic> json) => StocktakingLineDto(
        id: InventoryContractJson.text(json, 'id'),
        productId: InventoryContractJson.text(json, 'productId'),
        productBatchId: InventoryContractJson.nullableText(json['productBatchId']),
        expectedBaseQty: InventoryContractJson.decimal(json, 'expectedBaseQty', scale: 6),
        countedSealedCartons: InventoryContractJson.integer(json, 'countedSealedCartons'),
        countedLooseBaseQty: InventoryContractJson.decimal(json, 'countedLooseBaseQty', scale: 6),
        packConversionFactor: InventoryContractJson.decimal(json, 'packConversionFactor', scale: 6),
        countedBaseQty: InventoryContractJson.decimal(json, 'countedBaseQty', scale: 6),
        varianceBaseQty: InventoryContractJson.decimal(json, 'varianceBaseQty', scale: 6),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'productBatchId': productBatchId,
        'expectedBaseQty': expectedBaseQty.toFixedString(),
        'countedSealedCartons': countedSealedCartons,
        'countedLooseBaseQty': countedLooseBaseQty.toFixedString(),
        'packConversionFactor': packConversionFactor.toFixedString(),
        'countedBaseQty': countedBaseQty.toFixedString(),
        'varianceBaseQty': varianceBaseQty.toFixedString(),
      };
}

/// Disposal header and value.
final class DisposalDto {
  const DisposalDto({
    required this.id,
    required this.warehouseId,
    required this.disposalNo,
    required this.reason,
    required this.status,
    required this.disposalDate,
    required this.netValue,
    this.notes = '',
  });

  final String id;
  final String warehouseId;
  final String disposalNo;
  final String reason;
  final String status;
  final DateTime disposalDate;
  final MoneyAmount netValue;
  final String notes;

  factory DisposalDto.fromJson(Map<String, dynamic> json) => DisposalDto(
        id: InventoryContractJson.text(json, 'id'),
        warehouseId: InventoryContractJson.text(json, 'warehouseId'),
        disposalNo: InventoryContractJson.text(json, 'disposalNo'),
        reason: InventoryContractJson.text(json, 'reason'),
        status: InventoryContractJson.text(json, 'status'),
        disposalDate: InventoryContractJson.date(json, 'disposalDate'),
        netValue: InventoryContractJson.money(json, 'netValue'),
        notes: json['notes'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'warehouseId': warehouseId,
        'disposalNo': disposalNo,
        'reason': reason,
        'status': status,
        'disposalDate': disposalDate.toUtc().toIso8601String(),
        'netValue': netValue.toFixedString(),
        'notes': notes,
      };
}

/// Stock transfer header between two warehouses in the same branch.
final class StockTransferDto {
  const StockTransferDto({
    required this.id,
    required this.transferNo,
    required this.sourceWarehouseId,
    required this.destinationWarehouseId,
    required this.status,
    required this.transferDate,
  });

  final String id;
  final String transferNo;
  final String sourceWarehouseId;
  final String destinationWarehouseId;
  final String status;
  final DateTime transferDate;

  factory StockTransferDto.fromJson(Map<String, dynamic> json) => StockTransferDto(
        id: InventoryContractJson.text(json, 'id'),
        transferNo: InventoryContractJson.text(json, 'transferNo'),
        sourceWarehouseId: InventoryContractJson.text(json, 'sourceWarehouseId'),
        destinationWarehouseId: InventoryContractJson.text(json, 'destinationWarehouseId'),
        status: InventoryContractJson.text(json, 'status'),
        transferDate: InventoryContractJson.date(json, 'transferDate'),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'transferNo': transferNo,
        'sourceWarehouseId': sourceWarehouseId,
        'destinationWarehouseId': destinationWarehouseId,
        'status': status,
        'transferDate': transferDate.toUtc().toIso8601String(),
      };
}

/// Purchase invoice line including the free bonus quantity.
final class PurchaseInvoiceItemDto {
  const PurchaseInvoiceItemDto({
    required this.id,
    required this.productId,
    required this.qtyPaid,
    required this.bonusQty,
    required this.conversionFactor,
    required this.purchaseUnitPrice,
    required this.lineDiscountAmount,
    required this.lineTotal,
    required this.totalBaseUnitsAdded,
    required this.effectivePackCost,
    required this.effectiveBaseCost,
    this.unitId,
  });

  final String id;
  final String productId;
  final String? unitId;
  final ScaledDecimal qtyPaid;
  final ScaledDecimal bonusQty;
  final ScaledDecimal conversionFactor;
  final MoneyAmount purchaseUnitPrice;
  final MoneyAmount lineDiscountAmount;
  final MoneyAmount lineTotal;
  final ScaledDecimal totalBaseUnitsAdded;
  final MoneyAmount effectivePackCost;
  final ScaledDecimal effectiveBaseCost;

  factory PurchaseInvoiceItemDto.fromJson(Map<String, dynamic> json) => PurchaseInvoiceItemDto(
        id: InventoryContractJson.text(json, 'id'),
        productId: InventoryContractJson.text(json, 'productId'),
        unitId: InventoryContractJson.nullableText(json['unitId']),
        qtyPaid: InventoryContractJson.decimal(json, 'qtyPaid', scale: 4),
        bonusQty: InventoryContractJson.decimal(json, 'bonusQty', scale: 4),
        conversionFactor: InventoryContractJson.decimal(json, 'conversionFactor', scale: 6),
        purchaseUnitPrice: InventoryContractJson.money(json, 'purchaseUnitPrice'),
        lineDiscountAmount: InventoryContractJson.money(json, 'lineDiscountAmount'),
        lineTotal: InventoryContractJson.money(json, 'lineTotal'),
        totalBaseUnitsAdded: InventoryContractJson.decimal(json, 'totalBaseUnitsAdded', scale: 6),
        effectivePackCost: InventoryContractJson.money(json, 'effectivePackCost'),
        effectiveBaseCost: InventoryContractJson.decimal(json, 'effectiveBaseCost', scale: 6),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'unitId': unitId,
        'qtyPaid': qtyPaid.toFixedString(),
        'bonusQty': bonusQty.toFixedString(),
        'conversionFactor': conversionFactor.toFixedString(),
        'purchaseUnitPrice': purchaseUnitPrice.toFixedString(),
        'lineDiscountAmount': lineDiscountAmount.toFixedString(),
        'lineTotal': lineTotal.toFixedString(),
        'totalBaseUnitsAdded': totalBaseUnitsAdded.toFixedString(),
        'effectivePackCost': effectivePackCost.toFixedString(),
        'effectiveBaseCost': effectiveBaseCost.toFixedString(),
      };
}

/// Posted purchase invoice with supplier balance and payment details.
final class PurchaseInvoiceDto {
  const PurchaseInvoiceDto({
    required this.id,
    required this.invoiceNo,
    required this.supplierPartyId,
    required this.warehouseId,
    required this.invoiceDate,
    required this.subtotal,
    required this.discountAmount,
    required this.netTotal,
    required this.paidTotal,
    required this.items,
    required this.operationId,
    this.cashAccountId,
    this.walletRefNo,
  });

  final String id;
  final String invoiceNo;
  final String supplierPartyId;
  final String warehouseId;
  final DateTime invoiceDate;
  final MoneyAmount subtotal;
  final MoneyAmount discountAmount;
  final MoneyAmount netTotal;
  final MoneyAmount paidTotal;
  final String? cashAccountId;
  final String? walletRefNo;
  final String operationId;
  final List<PurchaseInvoiceItemDto> items;

  factory PurchaseInvoiceDto.fromJson(Map<String, dynamic> json) => PurchaseInvoiceDto(
        id: InventoryContractJson.text(json, 'id'),
        invoiceNo: InventoryContractJson.text(json, 'invoiceNo'),
        supplierPartyId: InventoryContractJson.text(json, 'supplierPartyId'),
        warehouseId: InventoryContractJson.text(json, 'warehouseId'),
        invoiceDate: InventoryContractJson.date(json, 'invoiceDate'),
        subtotal: InventoryContractJson.money(json, 'subtotal'),
        discountAmount: InventoryContractJson.money(json, 'discountAmount'),
        netTotal: InventoryContractJson.money(json, 'netTotal'),
        paidTotal: InventoryContractJson.money(json, 'paidTotal'),
        cashAccountId: InventoryContractJson.nullableText(json['cashAccountId']),
        walletRefNo: InventoryContractJson.nullableText(json['walletRefNo']),
        operationId: InventoryContractJson.text(json, 'operationId'),
        items: (json['items'] as List<dynamic>? ?? const [])
            .map((item) => PurchaseInvoiceItemDto.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'invoiceNo': invoiceNo,
        'supplierPartyId': supplierPartyId,
        'warehouseId': warehouseId,
        'invoiceDate': invoiceDate.toUtc().toIso8601String(),
        'subtotal': subtotal.toFixedString(),
        'discountAmount': discountAmount.toFixedString(),
        'netTotal': netTotal.toFixedString(),
        'paidTotal': paidTotal.toFixedString(),
        'cashAccountId': cashAccountId,
        'walletRefNo': walletRefNo,
        'operationId': operationId,
        'items': items.map((item) => item.toJson()).toList(growable: false),
      };
}

/// Supplier purchase return.
final class PurchaseReturnDto {
  const PurchaseReturnDto({
    required this.id,
    required this.returnNo,
    required this.purchaseInvoiceId,
    required this.supplierPartyId,
    required this.returnDate,
    required this.netTotal,
    required this.status,
  });

  final String id;
  final String returnNo;
  final String purchaseInvoiceId;
  final String supplierPartyId;
  final DateTime returnDate;
  final MoneyAmount netTotal;
  final String status;

  factory PurchaseReturnDto.fromJson(Map<String, dynamic> json) => PurchaseReturnDto(
        id: InventoryContractJson.text(json, 'id'),
        returnNo: InventoryContractJson.text(json, 'returnNo'),
        purchaseInvoiceId: InventoryContractJson.text(json, 'purchaseInvoiceId'),
        supplierPartyId: InventoryContractJson.text(json, 'supplierPartyId'),
        returnDate: InventoryContractJson.date(json, 'returnDate'),
        netTotal: InventoryContractJson.money(json, 'netTotal'),
        status: InventoryContractJson.text(json, 'status'),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'returnNo': returnNo,
        'purchaseInvoiceId': purchaseInvoiceId,
        'supplierPartyId': supplierPartyId,
        'returnDate': returnDate.toUtc().toIso8601String(),
        'netTotal': netTotal.toFixedString(),
        'status': status,
      };
}

/// A suggested reorder quantity and the supplier's decimal-safe effective cost.
final class ShortageOrderSuggestionDto {
  const ShortageOrderSuggestionDto({
    required this.productId,
    required this.productName,
    required this.currentBaseQty,
    required this.minimumBaseQty,
    required this.suggestedBaseQty,
    required this.effectiveBaseCost,
    this.supplierPartyId,
    this.supplierName,
  });

  final String productId;
  final String productName;
  final ScaledDecimal currentBaseQty;
  final ScaledDecimal minimumBaseQty;
  final ScaledDecimal suggestedBaseQty;
  final ScaledDecimal effectiveBaseCost;
  final String? supplierPartyId;
  final String? supplierName;

  factory ShortageOrderSuggestionDto.fromJson(Map<String, dynamic> json) =>
      ShortageOrderSuggestionDto(
        productId: InventoryContractJson.text(json, 'productId'),
        productName: InventoryContractJson.text(json, 'productName'),
        currentBaseQty: InventoryContractJson.decimal(json, 'currentBaseQty', scale: 6),
        minimumBaseQty: InventoryContractJson.decimal(json, 'minimumBaseQty', scale: 6),
        suggestedBaseQty: InventoryContractJson.decimal(json, 'suggestedBaseQty', scale: 6),
        effectiveBaseCost: InventoryContractJson.decimal(json, 'effectiveBaseCost', scale: 6),
        supplierPartyId: InventoryContractJson.nullableText(json['supplierPartyId']),
        supplierName: InventoryContractJson.nullableText(json['supplierName']),
      );

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'productName': productName,
        'currentBaseQty': currentBaseQty.toFixedString(),
        'minimumBaseQty': minimumBaseQty.toFixedString(),
        'suggestedBaseQty': suggestedBaseQty.toFixedString(),
        'effectiveBaseCost': effectiveBaseCost.toFixedString(),
        'supplierPartyId': supplierPartyId,
        'supplierName': supplierName,
      };
}
