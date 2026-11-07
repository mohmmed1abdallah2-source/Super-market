import 'dart:convert';
import 'package:flutter/material.dart';
import '../../data/database/database_helper.dart';
import '../../data/models/product_and_unit_models.dart';
import '../../providers/pos_and_catalog_provider.dart';
import 'package:provider/provider.dart';

/// Lists products and manages their unlimited sellable units and barcode prices.
class S08ProductsMultiUnitScreen extends StatefulWidget {
  const S08ProductsMultiUnitScreen({super.key});

  @override
  State<S08ProductsMultiUnitScreen> createState() => _S08ProductsMultiUnitScreenState();
}

class _S08ProductsMultiUnitScreenState extends State<S08ProductsMultiUnitScreen> {
  final _search = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<PosAndCatalogProvider>().loadCatalog());
    _search.addListener(() => setState(() => _filter = _search.text.trim()));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _addProduct,
      icon: const Icon(Icons.add),
      label: const Text('إضافة صنف'),
    ),
    body: Consumer<PosAndCatalogProvider>(
      builder: (context, provider, _) {
        final products = provider.products.where((p) =>
          p.nameAr.contains(_filter) || p.skuCode.contains(_filter)).toList();
        return Column(children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), labelText: 'بحث باسم الصنف أو الرمز',
              ),
            ),
          ),
          Expanded(child: products.isEmpty
            ? const Center(child: Text('لا توجد أصناف مطابقة'))
            : ListView.builder(
                itemCount: products.length,
                itemBuilder: (context, index) {
                  final product = products[index];
                  return FutureBuilder<List<ProductUnitBarcodeModel>>(
                    future: provider.unitsFor(product.id),
                    builder: (context, snapshot) {
                      final units = snapshot.data ?? [];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        child: ExpansionTile(
                          title: Text(product.nameAr),
                          subtitle: Text('رمز: ${product.skuCode} • المخزون: ${product.stockBaseQty} ${product.baseUnitName}'),
                          children: [
                            if (product.scalePluCode != null)
                              ListTile(title: Text('رقم الميزان PLU: ${product.scalePluCode}')),
                            TextButton.icon(
                              onPressed: () => _editProduct(product),
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('تعديل بيانات الصنف'),
                            ),
                            ...units.map((unit) => ListTile(
                              dense: true,
                              leading: const Icon(Icons.qr_code),
                              title: Text(unit.unitName),
                              subtitle: Text('باركود: ${unit.barcode ?? 'يقرأ من الميزان'} • معامل التحويل: ${unit.conversionFactor}'),
                              trailing: Text('تجزئة: ${unit.retailPrice.toStringAsFixed(2)}\nجملة: ${unit.wholesalePrice.toStringAsFixed(2)}'),
                            )),
                            TextButton.icon(
                              onPressed: () => _addUnit(product),
                              icon: const Icon(Icons.add),
                              label: const Text('إضافة وحدة وباركود'),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              )),
        ]);
      },
    ),
  );

  Future<void> _addProduct() async {
    final result = await showDialog<_ProductDraft>(
      context: context, builder: (_) => const _ProductDialog(),
    );
    if (result == null) return;
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().toIso8601String();
    final id = 'p-${DateTime.now().microsecondsSinceEpoch}';
    await db.transaction((txn) async {
      final productRow = <String, Object?>{
        'id': id, 'uuid': 'uuid-$id', 'branch_id': 'branch-main',
        'sku_code': result.sku, 'name_ar': result.name, 'name_en': null,
        'category_id': 'cat-grocery', 'brand_name': result.brand,
        'product_type': result.weighted ? 'WEIGHTED_SCALE' : 'STANDARD',
        'scale_plu_code': result.plu.isEmpty ? null : result.plu,
        'base_unit_name': result.baseUnit, 'stock_base_qty': 0,
        'avg_cost_base_unit': 0, 'last_cost_base_unit': 0,
        'min_stock_alert_qty': 0, 'reorder_qty': 0,
        'has_expiry_date': 0, 'nearest_expiry_date': null,
        'tax_rate_pct': 0, 'is_active': 1,
        'created_at': now, 'updated_at': now, 'is_deleted': 0,
        'sync_status': 'LOCAL', 'sync_version': 1,
      };
      await txn.insert('products', productRow);
      await _enqueueSync(txn, 'products', id, productRow, now);
      for (final unit in result.units) {
        await _insertUnit(txn, id, unit, now);
      }
    });
    await context.read<PosAndCatalogProvider>().loadCatalog();
  }

  Future<void> _editProduct(ProductModel product) async {
    final draft = await showDialog<_ProductEditDraft>(
      context: context,
      builder: (_) => _EditProductDialog(product: product),
    );
    if (draft == null) return;
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().toIso8601String();
    final updated = <String, Object?>{
      'name_ar': draft.name,
      'sku_code': draft.sku,
      'base_unit_name': draft.baseUnit,
      'brand_name': draft.brand,
      'product_type': draft.weighted ? 'WEIGHTED_SCALE' : 'STANDARD',
      'scale_plu_code': draft.plu.isEmpty ? null : draft.plu,
      'updated_at': now,
      'sync_version': 2,
    };
    await db.transaction((txn) async {
      await txn.update('products', updated, where: 'id=?', whereArgs: [product.id]);
      final row = (await txn.query('products', where: 'id=?', whereArgs: [product.id], limit: 1)).first;
      await _enqueueSync(txn, 'products', product.id, row, now);
    });
    await context.read<PosAndCatalogProvider>().loadCatalog();
  }

  Future<void> _addUnit(ProductModel product) async {
    final unit = await showDialog<_UnitDraft>(
      context: context, builder: (_) => const _UnitDialog(),
    );
    if (unit == null) return;
    final db = await DatabaseHelper.instance.database;
    await _insertUnit(db, product.id, unit, DateTime.now().toIso8601String());
    if (mounted) setState(() {});
  }

  Future<void> _insertUnit(dynamic db, String productId, _UnitDraft unit, String now) async {
    final id = 'unit-${DateTime.now().microsecondsSinceEpoch}';
    final row = <String, Object?>{
      'id': id, 'uuid': 'uuid-$id', 'branch_id': 'branch-main',
      'product_id': productId, 'unit_name': unit.name,
      'conversion_factor': unit.factor, 'barcode': unit.barcode.isEmpty ? null : unit.barcode,
      'cost_price': unit.cost, 'retail_price': unit.retail,
      'wholesale_price': unit.wholesale, 'min_sell_price': unit.minSell,
      'is_default_pos_unit': 0, 'created_at': now, 'updated_at': now,
      'is_deleted': 0, 'sync_status': 'LOCAL', 'sync_version': 1,
    };
    await db.insert('product_units_barcodes', row);
    await _enqueueSync(db, 'product_units_barcodes', id, row, now);
  }

  Future<void> _enqueueSync(
    dynamic db, String tableName, String rowId,
    Map<String, Object?> payload, String now,
  ) async {
    final queueId = 'sync-${DateTime.now().microsecondsSinceEpoch}';
    await db.insert('sync_queue', {
      'id': queueId, 'uuid': 'uuid-$queueId', 'branch_id': 'branch-main',
      'table_name': tableName, 'row_uuid': rowId, 'operation': 'INSERT',
      'payload_json': jsonEncode(payload), 'sync_version': 1,
      'batch_id': null, 'status': 'PENDING', 'queued_at': now,
      'created_at': now, 'updated_at': now, 'is_deleted': 0,
    });
  }
}

class _ProductEditDraft {
  const _ProductEditDraft(this.name, this.sku, this.baseUnit, this.brand, this.weighted, this.plu);
  final String name, sku, baseUnit, brand, plu;
  final bool weighted;
}

class _EditProductDialog extends StatefulWidget {
  const _EditProductDialog({required this.product});
  final ProductModel product;
  @override
  State<_EditProductDialog> createState() => _EditProductDialogState();
}

class _EditProductDialogState extends State<_EditProductDialog> {
  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _base;
  late final TextEditingController _brand;
  late final TextEditingController _plu;
  late bool _weighted;

  @override
  void initState() {
    super.initState();
    final product = widget.product;
    _name = TextEditingController(text: product.nameAr);
    _sku = TextEditingController(text: product.skuCode);
    _base = TextEditingController(text: product.baseUnitName);
    _brand = TextEditingController(text: product.brandName ?? '');
    _plu = TextEditingController(text: product.scalePluCode ?? '');
    _weighted = product.productType == 'WEIGHTED_SCALE';
  }

  @override
  void dispose() {
    _name.dispose(); _sku.dispose(); _base.dispose(); _brand.dispose(); _plu.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('تعديل بيانات الصنف'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: _name, decoration: const InputDecoration(labelText: 'اسم الصنف')),
      TextField(controller: _sku, decoration: const InputDecoration(labelText: 'رمز الصنف SKU')),
      TextField(controller: _base, decoration: const InputDecoration(labelText: 'وحدة الأساس')),
      TextField(controller: _brand, decoration: const InputDecoration(labelText: 'العلامة التجارية')),
      SwitchListTile(value: _weighted, onChanged: (value) => setState(() => _weighted = value), title: const Text('صنف موزون')),
      if (_weighted) TextField(controller: _plu, decoration: const InputDecoration(labelText: 'رقم PLU')),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
      FilledButton(onPressed: () {
        if (_name.text.trim().isEmpty || _sku.text.trim().isEmpty || _base.text.trim().isEmpty) return;
        Navigator.pop(context, _ProductEditDraft(
          _name.text.trim(), _sku.text.trim(), _base.text.trim(), _brand.text.trim(),
          _weighted, _plu.text.trim(),
        ));
      }, child: const Text('حفظ التعديل')),
    ],
  );
}

class _UnitDraft {
  const _UnitDraft(this.name, this.factor, this.barcode, this.cost, this.retail, this.wholesale, this.minSell);
  final String name, barcode;
  final double factor, cost, retail, wholesale, minSell;
}

class _ProductDraft {
  const _ProductDraft(this.name, this.sku, this.baseUnit, this.brand, this.weighted, this.plu, this.units);
  final String name, sku, baseUnit, brand, plu;
  final bool weighted;
  final List<_UnitDraft> units;
}

class _UnitEditor {
  _UnitEditor()
      : name = TextEditingController(),
        factor = TextEditingController(text: '1'),
        barcode = TextEditingController(),
        cost = TextEditingController(text: '0'),
        retail = TextEditingController(text: '0'),
        wholesale = TextEditingController(text: '0'),
        minSell = TextEditingController(text: '0');
  final TextEditingController name, factor, barcode, cost, retail, wholesale, minSell;
  _UnitDraft? build() {
    final f = double.tryParse(factor.text);
    final c = double.tryParse(cost.text);
    final r = double.tryParse(retail.text);
    final w = double.tryParse(wholesale.text);
    final m = double.tryParse(minSell.text);
    if (name.text.trim().isEmpty || f == null || f < 0.001 ||
        c == null || r == null || w == null || m == null) return null;
    return _UnitDraft(name.text.trim(), f, barcode.text.trim(), c, r, w, m);
  }
  void dispose() {
    name.dispose(); factor.dispose(); barcode.dispose(); cost.dispose();
    retail.dispose(); wholesale.dispose(); minSell.dispose();
  }
}

class _ProductDialog extends StatefulWidget {
  const _ProductDialog();
  @override
  State<_ProductDialog> createState() => _ProductDialogState();
}

class _ProductDialogState extends State<_ProductDialog> {
  final _name = TextEditingController();
  final _sku = TextEditingController();
  final _base = TextEditingController(text: 'حبة');
  final _brand = TextEditingController();
  final _plu = TextEditingController();
  bool _weighted = false;
  final List<_UnitEditor> _units = [_UnitEditor()..name.text = 'حبة'];

  @override
  void dispose() {
    _name.dispose(); _sku.dispose(); _base.dispose(); _brand.dispose(); _plu.dispose();
    for (final unit in _units) { unit.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('إضافة صنف جديد'),
    content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: _name, decoration: const InputDecoration(labelText: 'اسم الصنف بالعربية')),
      TextField(controller: _sku, decoration: const InputDecoration(labelText: 'رمز الصنف SKU')),
      TextField(controller: _base, decoration: const InputDecoration(labelText: 'وحدة الأساس')),
      TextField(controller: _brand, decoration: const InputDecoration(labelText: 'العلامة التجارية')),
      SwitchListTile(value: _weighted, onChanged: (v) => setState(() => _weighted = v), title: const Text('صنف موزون بباركود ميزان')),
      if (_weighted) TextField(controller: _plu, decoration: const InputDecoration(labelText: 'رقم PLU')),
      const Divider(),
      Row(children: [
        const Expanded(child: Text('وحدات البيع والأسعار')),
        IconButton(onPressed: () => setState(() => _units.add(_UnitEditor())), icon: const Icon(Icons.add_circle)),
      ]),
      ..._units.asMap().entries.map((entry) => _UnitFields(editor: entry.value, index: entry.key,
        onRemove: _units.length == 1 ? null : () => setState(() {
          final removed = _units.removeAt(entry.key); removed.dispose();
        }))),
    ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
      FilledButton(onPressed: _save, child: const Text('حفظ الصنف')),
    ],
  );

  void _save() {
    if (_name.text.trim().isEmpty || _sku.text.trim().isEmpty || _base.text.trim().isEmpty) return;
    final units = _units.map((e) => e.build()).toList();
    if (units.any((e) => e == null)) return;
    Navigator.pop(context, _ProductDraft(
      _name.text.trim(), _sku.text.trim(), _base.text.trim(), _brand.text.trim(),
      _weighted, _plu.text.trim(), units.cast<_UnitDraft>(),
    ));
  }
}

class _UnitDialog extends StatefulWidget {
  const _UnitDialog();
  @override
  State<_UnitDialog> createState() => _UnitDialogState();
}

class _UnitDialogState extends State<_UnitDialog> {
  final _editor = _UnitEditor();
  @override
  void dispose() { _editor.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('إضافة وحدة بيع'),
    content: SingleChildScrollView(child: _UnitFields(editor: _editor, index: 0)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
      FilledButton(onPressed: () {
        final unit = _editor.build();
        if (unit != null) Navigator.pop(context, unit);
      }, child: const Text('إضافة')),
    ],
  );
}

class _UnitFields extends StatelessWidget {
  const _UnitFields({required this.editor, required this.index, this.onRemove});
  final _UnitEditor editor;
  final int index;
  final VoidCallback? onRemove;
  @override
  Widget build(BuildContext context) => Card(child: Padding(
    padding: const EdgeInsets.all(10),
    child: Column(children: [
      Row(children: [
        Expanded(child: Text('الوحدة ${index + 1}')),
        if (onRemove != null) IconButton(onPressed: onRemove, icon: const Icon(Icons.remove_circle_outline)),
      ]),
      TextField(controller: editor.name, decoration: const InputDecoration(labelText: 'اسم الوحدة')),
      TextField(controller: editor.factor, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'معامل التحويل إلى وحدة الأساس')),
      TextField(controller: editor.barcode, decoration: const InputDecoration(labelText: 'الباركود (اختياري)')),
      Row(children: [
        Expanded(child: TextField(controller: editor.cost, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'التكلفة'))),
        const SizedBox(width: 8),
        Expanded(child: TextField(controller: editor.retail, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'سعر التجزئة'))),
      ]),
      Row(children: [
        Expanded(child: TextField(controller: editor.wholesale, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'سعر الجملة'))),
        const SizedBox(width: 8),
        Expanded(child: TextField(controller: editor.minSell, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'أقل سعر مسموح'))),
      ]),
    ]),
  ));
}