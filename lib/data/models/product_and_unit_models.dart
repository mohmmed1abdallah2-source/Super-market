/// Data models for product categories, sellable units and scale barcode results.
class ProductCategoryModel {
  const ProductCategoryModel({
    required this.id,
    this.parentId,
    required this.code,
    required this.nameAr,
    this.aisleLocation,
    this.isActive = true,
  });

  final String id;
  final String? parentId;
  final String code;
  final String nameAr;
  final String? aisleLocation;
  final bool isActive;

  factory ProductCategoryModel.fromMap(Map<String, Object?> map) =>
      ProductCategoryModel(
        id: map['id'] as String,
        parentId: map['parent_id'] as String?,
        code: map['code'] as String,
        nameAr: map['name_ar'] as String,
        aisleLocation: map['aisle_location'] as String?,
        isActive: (map['is_active'] as num? ?? 1) == 1,
      );

  Map<String, Object?> toMap() => {
    'id': id, 'parent_id': parentId, 'code': code, 'name_ar': nameAr,
    'aisle_location': aisleLocation, 'is_active': isActive ? 1 : 0,
  };
}

/// Represents a stock item whose quantity is always stored in its base unit.
class ProductModel {
  const ProductModel({
    required this.id,
    required this.skuCode,
    required this.nameAr,
    this.nameEn,
    this.categoryId,
    this.brandName,
    this.productType = 'STANDARD',
    this.scalePluCode,
    required this.baseUnitName,
    this.stockBaseQty = 0,
    this.avgCostBaseUnit = 0,
    this.lastCostBaseUnit = 0,
    this.minStockAlertQty = 0,
    this.reorderQty = 0,
    this.hasExpiryDate = false,
    this.nearestExpiryDate,
    this.taxRatePct = 0,
    this.isActive = true,
  });

  final String id;
  final String skuCode;
  final String nameAr;
  final String? nameEn;
  final String? categoryId;
  final String? brandName;
  final String productType;
  final String? scalePluCode;
  final String baseUnitName;
  final double stockBaseQty;
  final double avgCostBaseUnit;
  final double lastCostBaseUnit;
  final double minStockAlertQty;
  final double reorderQty;
  final bool hasExpiryDate;
  final String? nearestExpiryDate;
  final double taxRatePct;
  final bool isActive;

  factory ProductModel.fromMap(Map<String, Object?> map) => ProductModel(
    id: map['id'] as String,
    skuCode: map['sku_code'] as String,
    nameAr: map['name_ar'] as String,
    nameEn: map['name_en'] as String?,
    categoryId: map['category_id'] as String?,
    brandName: map['brand_name'] as String?,
    productType: map['product_type'] as String? ?? 'STANDARD',
    scalePluCode: map['scale_plu_code'] as String?,
    baseUnitName: map['base_unit_name'] as String,
    stockBaseQty: (map['stock_base_qty'] as num? ?? 0).toDouble(),
    avgCostBaseUnit: (map['avg_cost_base_unit'] as num? ?? 0).toDouble(),
    lastCostBaseUnit: (map['last_cost_base_unit'] as num? ?? 0).toDouble(),
    minStockAlertQty: (map['min_stock_alert_qty'] as num? ?? 0).toDouble(),
    reorderQty: (map['reorder_qty'] as num? ?? 0).toDouble(),
    hasExpiryDate: (map['has_expiry_date'] as num? ?? 0) == 1,
    nearestExpiryDate: map['nearest_expiry_date'] as String?,
    taxRatePct: (map['tax_rate_pct'] as num? ?? 0).toDouble(),
    isActive: (map['is_active'] as num? ?? 1) == 1,
  );

  Map<String, Object?> toMap() => {
    'id': id, 'sku_code': skuCode, 'name_ar': nameAr, 'name_en': nameEn,
    'category_id': categoryId, 'brand_name': brandName,
    'product_type': productType, 'scale_plu_code': scalePluCode,
    'base_unit_name': baseUnitName, 'stock_base_qty': stockBaseQty,
    'avg_cost_base_unit': avgCostBaseUnit, 'last_cost_base_unit': lastCostBaseUnit,
    'min_stock_alert_qty': minStockAlertQty, 'reorder_qty': reorderQty,
    'has_expiry_date': hasExpiryDate ? 1 : 0,
    'nearest_expiry_date': nearestExpiryDate, 'tax_rate_pct': taxRatePct,
    'is_active': isActive ? 1 : 0,
  };
}

/// Defines one scannable unit and its conversion and price rules for a product.
class ProductUnitBarcodeModel {
  const ProductUnitBarcodeModel({
    required this.id,
    required this.productId,
    required this.unitName,
    required this.conversionFactor,
    this.barcode,
    required this.costPrice,
    required this.retailPrice,
    required this.wholesalePrice,
    required this.minSellPrice,
    this.isDefaultPosUnit = false,
  }) : assert(conversionFactor > 0);

  final String id;
  final String productId;
  final String unitName;
  final double conversionFactor;
  final String? barcode;
  final double costPrice;
  final double retailPrice;
  final double wholesalePrice;
  final double minSellPrice;
  final bool isDefaultPosUnit;

  factory ProductUnitBarcodeModel.fromMap(Map<String, Object?> map) =>
      ProductUnitBarcodeModel(
        id: map['id'] as String,
        productId: map['product_id'] as String,
        unitName: map['unit_name'] as String,
        conversionFactor: (map['conversion_factor'] as num).toDouble(),
        barcode: map['barcode'] as String?,
        costPrice: (map['cost_price'] as num? ?? 0).toDouble(),
        retailPrice: (map['retail_price'] as num? ?? 0).toDouble(),
        wholesalePrice: (map['wholesale_price'] as num? ?? 0).toDouble(),
        minSellPrice: (map['min_sell_price'] as num? ?? 0).toDouble(),
        isDefaultPosUnit: (map['is_default_pos_unit'] as num? ?? 0) == 1,
      );

  Map<String, Object?> toMap() => {
    'id': id, 'product_id': productId, 'unit_name': unitName,
    'conversion_factor': conversionFactor, 'barcode': barcode,
    'cost_price': costPrice, 'retail_price': retailPrice,
    'wholesale_price': wholesalePrice, 'min_sell_price': minSellPrice,
    'is_default_pos_unit': isDefaultPosUnit ? 1 : 0,
  };
}

/// Holds the decoded product and quantity from a validated scale barcode.
class ScaleBarcodeResult {
  const ScaleBarcodeResult({
    required this.pluCode,
    required this.quantity,
    required this.quantityUnit,
    required this.rawBarcode,
    this.embeddedPrice,
  });

  final String pluCode;
  final double quantity;
  final String quantityUnit;
  final String rawBarcode;
  final double? embeddedPrice;

  bool get hasEmbeddedPrice => embeddedPrice != null;
}