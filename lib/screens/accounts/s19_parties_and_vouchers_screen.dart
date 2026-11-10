import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/pdf/receipt_and_ledger_pdf_builder.dart';
import '../../data/database/database_helper.dart';
import '../../data/models/erp_and_sync_models.dart';
import '../../providers/supermarket_erp_provider.dart';
import '../../providers/pos_and_ledger_provider.dart';

/// Manages customer/supplier balances, detailed statements and cash/wallet vouchers.
class S19PartiesAndVouchersScreen extends StatefulWidget {
  const S19PartiesAndVouchersScreen({super.key});

  @override
  State<S19PartiesAndVouchersScreen> createState() => _S19PartiesAndVouchersScreenState();
}

class _S19PartiesAndVouchersScreenState extends State<S19PartiesAndVouchersScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<SupermarketErpProvider>().loadParties());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _newVoucher,
      icon: const Icon(Icons.receipt_long),
      label: const Text('سند قبض / صرف'),
    ),
    body: Consumer<SupermarketErpProvider>(
      builder: (context, provider, _) => RefreshIndicator(
        onRefresh: provider.loadParties,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('العملاء والموردون', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _printPartyBalances('CUSTOMER'),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('ملخص أرصدة العملاء PDF'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _printPartyBalances('SUPPLIER'),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('ملخص أرصدة الموردين PDF'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (provider.parties.isEmpty)
              const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('لا توجد أطراف مسجلة')))
            else
              ...provider.parties.map((party) => FutureBuilder<Map<String, Object?>>(
                future: _balanceFor(party.id),
                builder: (context, snapshot) {
                  final balance = snapshot.data ?? const {};
                  return Card(child: ExpansionTile(
                    leading: CircleAvatar(child: Icon(party.partyType == 'SUPPLIER' ? Icons.local_shipping : Icons.person)),
                    title: Text(party.nameAr),
                    subtitle: Text('${party.code} • ${party.partyType == 'SUPPLIER' ? 'مورد' : 'عميل'}'),
                    trailing: snapshot.hasData
                      ? PartyBalanceChip(
                          totalAlayh: (balance['total_alayh'] as num? ?? 0),
                          totalLah: (balance['total_lah'] as num? ?? 0),
                        )
                      : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    children: [
                      if (party.phone != null && party.phone!.isNotEmpty)
                        ListTile(leading: const Icon(Icons.phone), title: Text(party.phone!)),
                      if (party.address != null && party.address!.isNotEmpty)
                        ListTile(leading: const Icon(Icons.location_on_outlined), title: Text(party.address!)),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton.icon(
                          onPressed: () => _showStatement(party),
                          icon: const Icon(Icons.receipt_long),
                          label: const Text('عرض كشف الحساب'),
                        ),
                      ),
                    ],
                  ));
                },
              )),
            const SizedBox(height: 80),
          ],
        ),
      ),
    ),
  );

  Future<Map<String, Object?>> _balanceFor(String partyId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('v_party_balance',
      where: 'party_id=?', whereArgs: [partyId], limit: 1);
    return rows.isEmpty ? const {'total_alayh': 0, 'total_lah': 0} : rows.first;
  }

  Future<void> _showStatement(PartyModel party) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('lah_alayh_ledger',
      where: 'party_id=? AND is_deleted=0', whereArgs: [party.id],
      orderBy: 'entry_date DESC');
    if (!mounted) return;
    final balance = await _balanceFor(party.id);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('كشف حساب: ${party.nameAr}'),
        content: SizedBox(width: 650, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PartyBalanceChip(
              totalAlayh: (balance['total_alayh'] as num? ?? 0),
              totalLah: (balance['total_lah'] as num? ?? 0),
            ),
            const SizedBox(height: 12),
            LahAlayhTable(entries: rows),
          ],
        ))),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await ReceiptAndLedgerPdfBuilder.previewPartyStatement(
                party: party,
                entries: rows,
                totalAlayh: (balance['total_alayh'] as num? ?? 0).toDouble(),
                totalLah: (balance['total_lah'] as num? ?? 0).toDouble(),
              );
            },
            icon: const Icon(Icons.picture_as_pdf),
            label: const Text('طباعة كشف الحساب الرسمي PDF'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
        ],
      ),
    );
  }

  Future<void> _printPartyBalances(String partyType) async {
    final user = context.read<SupermarketErpProvider>().currentUser;
    if (user == null) return;
    final ledger = context.read<PosAndLedgerProvider>();
    await ledger.refresh(user['branch_id'] as String);
    if (!mounted) return;
    await ReceiptAndLedgerPdfBuilder.previewPartyBalances(
      parties: ledger.partyBalances,
      partyType: partyType,
    );
  }

  Future<void> _newVoucher() async {
    final provider = context.read<SupermarketErpProvider>();
    if (provider.parties.isEmpty) await provider.loadParties();
    if (!mounted) return;
    final draft = await showModalBottomSheet<_VoucherDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => KeyboardSafeModalSheet(
        child: _VoucherDialog(parties: provider.parties),
      ),
    );
    if (draft == null) return;
    try {
      await _saveVoucher(draft);
      await provider.loadParties();
      await provider.loadVouchers();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ السند وترحيله محلياً')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ السند: $error')),
        );
      }
    }
  }

  Future<void> _saveVoucher(_VoucherDraft draft) async {
    final erp = context.read<SupermarketErpProvider>();
    final user = erp.currentUser;
    if (user == null) throw StateError('يجب تسجيل الدخول أولاً');
    final branchId = user['branch_id'] as String;
    await context.read<PosAndLedgerProvider>().postVoucher(
      branchId: branchId,
      partyId: draft.partyId,
      cashAccountId: draft.cashAccountId,
      voucherType: draft.type,
      method: draft.method,
      amount: draft.amount,
      walletRefNo: draft.method == 'WALLET' ? draft.reference.trim() : null,
      description: draft.description,
    );
  }
}

class _VoucherDraft {
  const _VoucherDraft({
    required this.type, required this.partyId, required this.cashAccountId,
    required this.amount, required this.method, required this.reference,
    required this.description,
  });
  final String type, partyId, cashAccountId, method, reference, description;
  final double amount;
}

class _VoucherDialog extends StatefulWidget {
  const _VoucherDialog({required this.parties});
  final List<PartyModel> parties;
  @override
  State<_VoucherDialog> createState() => _VoucherDialogState();
}

class _VoucherDialogState extends State<_VoucherDialog> {
  String _type = 'RECEIPT';
  String? _partyId;
  String _accountId = 'cash-drawer';
  String _method = 'CASH';
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _description = TextEditingController(text: 'سند تسوية حساب');

  @override
  void initState() {
    super.initState();
    _partyId = widget.parties.where((party) => party.partyType == 'CUSTOMER').isEmpty
        ? null
        : widget.parties.firstWhere((party) => party.partyType == 'CUSTOMER').id;
  }

  @override
  void dispose() {
    _amount.dispose(); _reference.dispose(); _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('إصدار سند'),
    content: SizedBox(width: 500, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      DropdownButtonFormField<String>(
        initialValue: _type,
        decoration: const InputDecoration(labelText: 'نوع السند'),
        items: const [
          DropdownMenuItem(value: 'RECEIPT', child: Text('سند قبض')),
          DropdownMenuItem(value: 'PAYMENT', child: Text('سند صرف')),
        ],
        onChanged: (v) => setState(() {
          _type = v ?? 'RECEIPT';
          final eligible = widget.parties.where((party) =>
            _type == 'RECEIPT' ? party.partyType == 'CUSTOMER' : party.partyType == 'SUPPLIER');
          _partyId = eligible.isEmpty ? null : eligible.first.id;
        }),
      ),
      DropdownButtonFormField<String>(
        initialValue: _partyId,
        decoration: const InputDecoration(labelText: 'الطرف'),
        items: widget.parties.where((party) =>
          _type == 'RECEIPT' ? party.partyType == 'CUSTOMER' : party.partyType == 'SUPPLIER')
          .map((p) => DropdownMenuItem(value: p.id, child: Text(p.nameAr))).toList(),
        onChanged: (v) => setState(() => _partyId = v),
      ),
      TextField(controller: _amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ')),
      DropdownButtonFormField<String>(
        initialValue: _method,
        decoration: const InputDecoration(labelText: 'طريقة الدفع'),
        items: const [
          DropdownMenuItem(value: 'CASH', child: Text('نقداً')),
          DropdownMenuItem(value: 'WALLET', child: Text('محفظة')),
        ],
        onChanged: (v) => setState(() {
          _method = v ?? 'CASH';
          _accountId = _method == 'CASH' ? 'cash-drawer' : 'wallet-jawali';
        }),
      ),
      if (_method == 'WALLET') ...[
        DropdownButtonFormField<String>(
          initialValue: _accountId,
          decoration: const InputDecoration(labelText: 'المحفظة'),
          items: const [
            DropdownMenuItem(value: 'wallet-jawali', child: Text('جوالي')),
            DropdownMenuItem(value: 'wallet-jaib', child: Text('جيب')),
            DropdownMenuItem(value: 'wallet-flousk', child: Text('فلوسك')),
            DropdownMenuItem(value: 'wallet-kuraimi', child: Text('كريمي')),
          ],
          onChanged: (v) => setState(() => _accountId = v ?? 'wallet-jawali'),
        ),
        WalletRefField(controller: _reference),
      ],
      TextField(controller: _description, decoration: const InputDecoration(labelText: 'البيان')),
    ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
      FilledButton(onPressed: _save, child: const Text('حفظ السند')),
    ],
  );

  void _save() {
    final amount = double.tryParse(_amount.text);
    if (_partyId == null || amount == null || amount <= 0 ||
        (_method == 'WALLET' && _reference.text.trim().length < 6)) {
      return;
    }
    Navigator.pop(context, _VoucherDraft(
      type: _type, partyId: _partyId!, cashAccountId: _accountId,
      amount: amount, method: _method, reference: _reference.text,
      description: _description.text.trim(),
    ));
  }
}