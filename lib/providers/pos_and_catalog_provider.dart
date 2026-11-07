import 'package:flutter/foundation.dart';
import '../data/database/database_helper.dart';
import '../data/models/erp_and_sync_models.dart';
import '../data/models/product_and_unit_models.dart';
import '../data/services/scale_and_pos_service.dart';

/// Manages the product catalogue and up to eight independent cashier invoice tabs.
class PosAndCatalogProvider extends ChangeNotifier {
  PosAndCatalogProvider({
    DatabaseHelper? databaseHelper,
    ScaleAndBarcodeParser? parser,
  })  : _helper = databaseHelper ?? DatabaseHelper.instance,
        _parser = parser ?? const ScaleAndBarcodeParser();

  final DatabaseHelper _helper;
  final ScaleAndBarcodeParser _parser;
  final List<PosTabSession> _tabs = [];
  int _activeIndex = 0;
  List<ProductModel> _products = [];
  String? _lastError;

  List<PosTabSession> get tabs => List.unmodifiable(_tabs);
  List<ProductModel> get products => List.unmodifiable(_products);
  int get activeIndex => _activeIndex;
  String? get lastError => _lastError;
  PosTabSession? get activeTab => _tabs.isEmpty ? null : _tabs[_activeIndex];
  double get activeSubtotal => activeTab?.subtotal ?? 0;

  /// Loads active products from SQLite for instant local catalogue access.
  Future<void> loadCatalog() async {
    final db = await _helper.database;
    final rows = await db.query('products',
      where: 'is_active=1 AND is_deleted=0', orderBy: 'name_ar COLLATE NOCASE');
    _products = rows.map(ProductModel.fromMap).toList();
    notifyListeners();
  }

  /// Creates a new invoice tab, up to the eight-tab cashier limit.
  bool createTab({String? label}) {
    if (_tabs.length >= 8) {
      _lastError = 'يمكن فتح ثماني فواتير فقط في الوقت نفسه';
      notifyListeners();
      return false;
    }
    _tabs.add(PosTabSession(
      id: 'tab-\${DateTime.now().microsecondsSinceEpoch}',
      label: label ?? 'فاتورة \${_tabs.length + 1}',
    ));
    _activeIndex = _tabs.length - 1;
    _lastError = null;
    notifyListeners();
    return true;
  }

  /// Switches the cashier workspace to an existing invoice tab.
  void selectTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _activeIndex = index;
    notifyListeners();
  }

  /// Closes an empty or explicitly confirmed tab and selects a remaining tab.
  bool closeTab(int index, {bool discardNonEmpty = false}) {
    if (index < 0 || index >= _tabs.length) return false;
    if (_tabs[index].items.isNotEmpty && !discardNonEmpty) {
      _lastError = 'الفاتورة تحتوي أصنافاً؛ أكد الإلغاء أولاً';
      notifyListeners();
      return false;
    }
    _tabs.removeAt(index);
    if (_tabs.isEmpty) {
      _activeIndex = 0;
    } else if (_activeIndex >= _tabs.length) {
      _activeIndex = _tabs.length - 1;
    } else if (_activeIndex > index) {
      _activeIndex--;
    }
    notifyListeners();
    return true;
  }

  /// Changes the current tab's price tier and refreshes every line's unit price.
  Future<void> setPriceTier(String tier) async {
    if (!['RETAIL', 'WHOLESALE'].contains(tier) || activeTab == null) return;
    final db = await _helper.database;
    final tab = activeTab!;
    tab.priceTier = tier;
    for (var i = 0; i < tab.items.length; i++) {
      final item = tab.items[i];
      final rows = await db.query('product_units_barcodes',
        columns: ['retail_price', 'wholesale_price'],
        where: 'id=?', whereArgs: [item.unitId], limit: 1);
      if (rows.isEmpty) continue;
      final price = (rows.first[tier == 'RETAIL' ? 'retail_price' : 'wholesale_price'] as num).toDouble();
      tab.items[i] = item.copyWith(unitPrice: price);
    }
    notifyListeners();
  }

  /// Resolves and adds a scanned unit or scale label to the active invoice.
  Future<bool> addBarcode(String barcode) async {
    if (activeTab == null && !createTab()) return false;
    try {
      final match = await _parser.lookup(barcode);
      if (match == null) {
        _lastError = 'الباركود غير مسجل في دليل الأصناف';
        notifyListeners();
        return false;
      }
      final scale = match.scaleResult;
      final quantity = scale?.quantity ?? 1.0;
      final conversion = scale == null
          ? match.unit.conversionFactor
          : match.unit.conversionFactor;
      final price = activeTab!.priceTier == 'RETAIL'
          ? match.unit.retailPrice : match.unit.wholesalePrice;
      final tab = activeTab!;
      final existingIndex = tab.items.indexWhere((item) =>
        item.productId == match.product.id && item.unitId == match.unit.id &&
        scale == null);
      if (existingIndex >= 0) {
        final old = tab.items[existingIndex];
        tab.items[existingIndex] = old.copyWith(quantity: old.quantity + quantity);
      } else {
        tab.items.add(PosCartItemModel(
          productId: match.product.id,
          unitId: match.unit.id,
          productName: match.product.nameAr,
          unitName: match.unit.unitName,
          conversionFactor: conversion,
          quantity: quantity,
          unitPrice: price,
          unitCost: match.unit.costPrice / match.unit.conversionFactor,
        ));
      }
      _lastError = null;
      notifyListeners();
      return true;
    } catch (error) {
      _lastError = 'تعذر قراءة الباركود: $error';
      notifyListeners();
      return false;
    }
  }

  /// Adds a known product unit using the selected retail or wholesale price.
  Future<void> addUnit(ProductModel product, ProductUnitBarcodeModel unit) async {
    if (activeTab == null && !createTab()) return;
    final price = activeTab!.priceTier == 'RETAIL' ? unit.retailPrice : unit.wholesalePrice;
    activeTab!.items.add(PosCartItemModel(
      productId: product.id, unitId: unit.id, productName: product.nameAr,
      unitName: unit.unitName, conversionFactor: unit.conversionFactor,
      quantity: 1, unitPrice: price,
      unitCost: unit.costPrice / unit.conversionFactor,
    ));
    notifyListeners();
  }

  /// Updates the quantity for one cart line after validating a positive value.
  void updateQuantity(int index, double quantity) {
    final tab = activeTab;
    if (tab == null || index < 0 || index >= tab.items.length || quantity <= 0) return;
    tab.items[index] = tab.items[index].copyWith(quantity: quantity);
    notifyListeners();
  }

  /// Removes one cart line from the active invoice.
  void removeItem(int index) {
    final tab = activeTab;
    if (tab == null || index < 0 || index >= tab.items.length) return;
    tab.items.removeAt(index);
    notifyListeners();
  }

  /// Marks the active tab as held without posting inventory or accounting changes.
  void holdActiveTab({String? label}) {
    final tab = activeTab;
    if (tab == null) return;
    tab.isHeld = true;
    if (label != null) tab.label = label;
    notifyListeners();
  }

  /// Assigns the selected customer to the active invoice.
  void setCustomer(String? partyId) {
    if (activeTab == null) return;
    activeTab!.customerPartyId = partyId;
    notifyListeners();
  }

  /// Clears the current tab after a successful sale commit.
  void clearActiveAfterSale() {
    final tab = activeTab;
    if (tab == null) return;
    tab.items.clear();
    tab.customerPartyId = null;
    tab.isHeld = false;
    notifyListeners();
  }

  /// Loads sellable unit options for a product.
  Future<List<ProductUnitBarcodeModel>> unitsFor(String productId) async {
    final db = await _helper.database;
    final rows = await db.query('product_units_barcodes',
      where: 'product_id=? AND is_deleted=0', whereArgs: [productId],
      orderBy: 'is_default_pos_unit DESC, conversion_factor ASC');
    return rows.map(ProductUnitBarcodeModel.fromMap).toList();
  }
}