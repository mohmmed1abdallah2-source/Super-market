import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/theme/enterprise_dark_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../data/models/erp_and_sync_models.dart';
import '../../data/services/scale_and_pos_service.dart';
import '../../providers/pos_and_catalog_provider.dart';
import '../../providers/supermarket_erp_provider.dart';

/// Fast cashier workspace with multi-invoice tabs, barcode entry and payment posting.
class S03SupermarketPosScreen extends StatefulWidget {
  const S03SupermarketPosScreen({super.key});

  @override
  State<S03SupermarketPosScreen> createState() => _S03SupermarketPosScreenState();
}

class _S03SupermarketPosScreenState extends State<S03SupermarketPosScreen> {
  final _barcodeController = TextEditingController();
  final _barcodeFocus = FocusNode();
  bool _posting = false;

  @override
  void dispose() {
    _barcodeController.dispose();
    _barcodeFocus.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = _barcodeController.text.trim();
    if (code.isEmpty) return;
    _barcodeController.clear();
    final success = await context.read<PosAndCatalogProvider>().addBarcode(code);
    if (!success && mounted) {
      final message = context.read<PosAndCatalogProvider>().lastError ?? 'تعذر إضافة الصنف';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
    _barcodeFocus.requestFocus();
  }

  Future<void> _checkout() async {
    final pos = context.read<PosAndCatalogProvider>();
    final erp = context.read<SupermarketErpProvider>();
    final tab = pos.activeTab;
    if (tab == null || tab.items.isEmpty || erp.currentUser == null) return;
    final draft = await showDialog<_PaymentDraft>(
      context: context,
      builder: (context) => _PaymentDialog(total: pos.activeSubtotal),
    );
    if (draft == null || !mounted) return;
    if (draft.method != 'CREDIT' && draft.amount <= 0) return;
    if (draft.method == 'WALLET' && draft.reference.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('رقم إشعار المحفظة مطلوب')));
      return;
    }
    setState(() => _posting = true);
    try {
      final payments = draft.method == 'CREDIT'
          ? <SalePaymentInput>[]
          : [SalePaymentInput(
              method: draft.method,
              amount: draft.amount,
              cashAccountId: draft.accountId,
              walletRefNo: draft.method == 'WALLET' ? draft.reference.trim() : null,
            )];
      final user = erp.currentUser!;
      final result = await PostingAndSalesService().completeSale(
        branchId: user['branch_id'] as String,
        cashierUserId: user['id'] as String,
        items: List<PosCartItemModel>.from(tab.items),
        priceTier: tab.priceTier,
        payments: payments,
        customerPartyId: tab.customerPartyId,
      );
      pos.clearActiveAfterSale();
      await erp.loadDashboard();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم حفظ الفاتورة محلياً رقم ${result.invoiceNo}')),
        );
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('لم تُحفظ الفاتورة: $error')),
      );
    } finally {
      if (mounted) setState(() => _posting = false);
      _barcodeFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PosAndCatalogProvider>(
      builder: (context, provider, _) {
        final tab = provider.activeTab;
        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f4) {
              provider.holdActiveTab();
              return KeyEventResult.handled;
            }
            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f6) {
              provider.createTab();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Column(children: [
            _buildTabs(provider),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: TextField(
                  controller: _barcodeController,
                  focusNode: _barcodeFocus,
                  autofocus: true,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.qr_code_scanner),
                    labelText: 'امسح باركود الصنف أو باركود الميزان',
                    hintText: 'أدخل الرمز ثم اضغط Enter',
                  ),
                  onSubmitted: (_) => _scan(),
                )),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _scan,
                  icon: const Icon(Icons.add),
                  tooltip: 'إضافة الصنف',
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  onPressed: () => provider.addBarcode('2010250125000'),
                  icon: const Icon(Icons.scale),
                  label: const Text('تجربة الميزان'),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                const Text('نوع السعر:'),
                const SizedBox(width: 10),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'RETAIL', label: Text('سعر تجزئة')),
                    ButtonSegment(value: 'WHOLESALE', label: Text('سعر جملة')),
                  ],
                  selected: {tab?.priceTier ?? 'RETAIL'},
                  onSelectionChanged: (value) => provider.setPriceTier(value.first),
                ),
                const Spacer(),
                Text('F4 تعليق  •  F6 فاتورة جديدة', style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Consumer<SupermarketErpProvider>(
                builder: (context, erp, _) => DropdownButtonFormField<String?>(
                  value: tab?.customerPartyId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'العميل (مطلوب عند البيع الآجل)',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('عميل نقدي / بدون حساب')),
                    ...erp.parties.where((party) => party.partyType == 'CUSTOMER')
                      .map((party) => DropdownMenuItem<String?>(
                        value: party.id, child: Text(party.nameAr),
                      )),
                  ],
                  onChanged: (value) => provider.setCustomer(value),
                ),
              ),
            ),
            const Divider(height: 20),
            Expanded(child: tab == null || tab.items.isEmpty
              ? const Center(child: Text('امسح باركود الصنف لبدء الفاتورة'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: tab.items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = tab.items[index];
                    return ListTile(
                      title: Text(item.productName),
                      subtitle: Text('${item.unitName} • ${item.quantity} × ${MoneyFormatter().format(item.unitPrice)}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(MoneyFormatter().format(item.lineTotal)),
                        IconButton(
                          onPressed: () => provider.removeItem(index),
                          icon: const Icon(Icons.delete_outline, color: EnterpriseDarkTheme.danger),
                        ),
                      ]),
                    );
                  },
                )),
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: const BoxDecoration(
                  color: EnterpriseDarkTheme.surface,
                  border: Border(top: BorderSide(color: EnterpriseDarkTheme.outline)),
                ),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('إجمالي الفاتورة'),
                    Text(MoneyFormatter().format(provider.activeSubtotal),
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: EnterpriseDarkTheme.primary)),
                  ])),
                  FilledButton.icon(
                    onPressed: _posting || tab == null || tab.items.isEmpty ? null : _checkout,
                    icon: _posting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.payment),
                    label: const Text('الدفع وحفظ الفاتورة'),
                  ),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _buildTabs(PosAndCatalogProvider provider) => SizedBox(
    height: 58,
    child: Row(children: [
      Expanded(child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: provider.tabs.length,
        itemBuilder: (context, index) {
          final tab = provider.tabs[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: ChoiceChip(
              label: Text(tab.label),
              selected: provider.activeIndex == index,
              onSelected: (_) => provider.selectTab(index),
              avatar: tab.isHeld ? const Icon(Icons.pause, size: 16) : null,
            ),
          );
        },
      )),
      IconButton(
        onPressed: provider.tabs.length >= 8 ? null : () => provider.createTab(),
        icon: const Icon(Icons.add_circle_outline),
        tooltip: 'فاتورة جديدة (F6)',
      ),
    ]),
  );
}

class _PaymentDraft {
  const _PaymentDraft(this.method, this.amount, this.accountId, this.reference);
  final String method;
  final double amount;
  final String? accountId;
  final String reference;
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.total});
  final double total;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  String _method = 'CASH';
  String _account = 'cash-drawer';
  final _amount = TextEditingController();
  final _reference = TextEditingController();

  @override
  void initState() {
    super.initState();
    _amount.text = widget.total.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('طريقة الدفع'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      DropdownButtonFormField<String>(
        value: _method,
        decoration: const InputDecoration(labelText: 'طريقة السداد'),
        items: const [
          DropdownMenuItem(value: 'CASH', child: Text('نقداً')),
          DropdownMenuItem(value: 'WALLET', child: Text('محفظة إلكترونية')),
          DropdownMenuItem(value: 'CREDIT', child: Text('آجل على حساب العميل')),
        ],
        onChanged: (value) => setState(() {
          _method = value ?? 'CASH';
          _account = _method == 'CASH' ? 'cash-drawer' : 'wallet-jawali';
        }),
      ),
      if (_method != 'CREDIT') ...[
        const SizedBox(height: 10),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'المبلغ المدفوع'),
        ),
      ],
      if (_method == 'WALLET') ...[
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _account,
          decoration: const InputDecoration(labelText: 'المحفظة'),
          items: const [
            DropdownMenuItem(value: 'wallet-jawali', child: Text('جوالي')),
            DropdownMenuItem(value: 'wallet-jaib', child: Text('جيب')),
            DropdownMenuItem(value: 'wallet-flousk', child: Text('فلوسك')),
            DropdownMenuItem(value: 'wallet-kuraimi', child: Text('كريمي')),
          ],
          onChanged: (value) => setState(() => _account = value ?? 'wallet-jawali'),
        ),
        const SizedBox(height: 10),
        WalletRefField(controller: _reference),
      ],
      if (_method == 'CREDIT')
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('سيتم تسجيل كامل المبلغ على حساب العميل المحدد.'),
        ),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
      FilledButton(
        onPressed: () {
          final amount = _method == 'CREDIT' ? 0.0 : double.tryParse(_amount.text) ?? 0;
          Navigator.pop(context, _PaymentDraft(_method, amount, _method == 'CREDIT' ? null : _account, _reference.text));
        },
        child: const Text('متابعة'),
      ),
    ],
  );
}