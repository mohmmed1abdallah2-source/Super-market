import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/enterprise_dark_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../data/database/database_helper.dart';
import '../../data/models/erp_and_sync_models.dart';
import '../../providers/supermarket_erp_provider.dart';

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
            if (provider.parties.isEmpty)
              const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('لا توجد أطراف مسجلة')))
            else
              ...provider.parties.map((party) => FutureBuilder<Map<String, Object?>>(
                future: _balanceFor(party.id),
                builder: (context, snapshot) {
                  final balance = snapshot.data ?? const {};
                  return Card(child: ListTile(
                    leading: CircleAvatar(child: Icon(party.partyType == 'SUPPLIER' ? Icons.local_shipping : Icons.person)),
                    title: Text(party.nameAr),
                    subtitle: Text('\${party.code} • \${party.partyType == 'SUPPLIER' ? 'مورد' : 'عميل'}'),
                    trailing: snapshot.hasData
                      ? PartyBalanceChip(
                          totalAlayh: (balance['total_alayh'] as num? ?? 0),
                          totalLah: (balance['total_lah'] as num? ?? 0),
                        )
                      : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    onTap: () => _showStatement(party),
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
        title: Text('كشف حساب: \${party.nameAr}'),
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
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
      ),
    );
  }

  Future<void> _newVoucher() async {
    final provider = context.read<SupermarketErpProvider>();
    if (provider.parties.isEmpty) await provider.loadParties();
    if (!mounted) return;
    final draft = await showDialog<_VoucherDraft>(
      context: context,
      builder: (context) => _VoucherDialog(parties: provider.parties),
    );
    if (draft == null) return;
    try {
      await _saveVoucher(draft);
      await provider.loadParties();
      await provider.loadVouchers();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ السند وترحيله محلياً')),
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر حفظ السند: $error')),
      );
    }
  }

  Future<void> _saveVoucher(_VoucherDraft draft) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().toIso8601String();
    final id = 'voucher-\${DateTime.now().microsecondsSinceEpoch}';
    final journalId = 'journal-\${DateTime.now().microsecondsSinceEpoch}';
    final ledgerId = 'ledger-\${DateTime.now().microsecondsSinceEpoch}';
    await db.transaction((txn) async {
      final cashRows = await txn.query('cash_accounts',
        where: 'id=? AND is_deleted=0', whereArgs: [draft.cashAccountId], limit: 1);
      if (cashRows.isEmpty) throw StateError('الصندوق أو المحفظة غير موجودة');
      final currentBalance = (cashRows.first['current_balance'] as num).toDouble();
      final isReceipt = draft.type == 'RECEIPT';
      if (!isReceipt && currentBalance < draft.amount) {
        throw StateError('الرصيد المتاح في الصندوق أو المحفظة غير كافٍ');
      }
      if (draft.method == 'WALLET' && draft.reference.trim().isEmpty) {
        throw StateError('رقم إشعار المحفظة مطلوب');
      }
      final voucherNo = 'V-\${DateTime.now().millisecondsSinceEpoch}';
      await txn.insert('vouchers', {
        'id': id, 'uuid': 'uuid-$id', 'branch_id': 'branch-main',
        'voucher_no': voucherNo, 'voucher_type': draft.type,
        'voucher_date': now, 'party_id': draft.partyId,
        'cash_account_id': draft.cashAccountId, 'amount': draft.amount,
        'method': draft.method, 'wallet_ref_no': draft.method == 'WALLET' ? draft.reference.trim() : null,
        'description': draft.description, 'journal_entry_id': journalId,
        'created_at': now, 'updated_at': now, 'is_deleted': 0,
        'sync_status': 'LOCAL', 'sync_version': 1,
      });
      await txn.insert('journal_entries', {
        'id': journalId, 'uuid': 'uuid-$journalId', 'branch_id': 'branch-main',
        'entry_no': voucherNo, 'entry_date': now, 'doc_type': 'VOUCHER',
        'doc_id': id, 'description': draft.description,
        'created_at': now, 'updated_at': now, 'is_deleted': 0,
        'sync_status': 'LOCAL', 'sync_version': 1,
      });
      final cashLine = 'jl-cash-\${DateTime.now().microsecondsSinceEpoch}';
      final partyLine = 'jl-party-\${DateTime.now().microsecondsSinceEpoch}';
      await txn.insert('journal_lines', {
        'id': cashLine, 'uuid': 'uuid-$cashLine', 'branch_id': 'branch-main',
        'journal_entry_id': journalId,
        'gl_account_id': isReceipt ? 'gl-cash' : 'gl-payable',
        'dr_amount': isReceipt ? draft.amount : 0,
        'cr_amount': isReceipt ? 0 : draft.amount,
        'created_at': now, 'updated_at': now, 'is_deleted': 0,
        'sync_status': 'LOCAL', 'sync_version': 1,
      });
      await txn.insert('journal_lines', {
        'id': partyLine, 'uuid': 'uuid-$partyLine', 'branch_id': 'branch-main',
        'journal_entry_id': journalId,
        'gl_account_id': isReceipt ? 'gl-receivable' : 'gl-cash',
        'dr_amount': isReceipt ? 0 : draft.amount,
        'cr_amount': isReceipt ? draft.amount : 0,
        'created_at': now, 'updated_at': now, 'is_deleted': 0,
        'sync_status': 'LOCAL', 'sync_version': 1,
      });
      await txn.rawUpdate(
        'UPDATE cash_accounts SET current_balance=current_balance+?, updated_at=? WHERE id=?',
        [isReceipt ? draft.amount : -draft.amount, now, draft.cashAccountId]);
      await txn.insert('lah_alayh_ledger', {
        'id': ledgerId, 'uuid': 'uuid-$ledgerId', 'branch_id': 'branch-main',
        'party_id': draft.partyId, 'entry_date': now,
        'entry_type': draft.type,
        'alayh_amount': isReceipt ? 0 : draft.amount,
        'lah_amount': isReceipt ? draft.amount : 0,
        'doc_type': 'VOUCHER', 'doc_id': id,
        'statement_ar': draft.description, 'journal_entry_id': journalId,
        'created_at': now, 'updated_at': now, 'is_deleted': 0,
        'sync_status': 'LOCAL', 'sync_version': 1,
      });
      final queueId = 'sync-\${DateTime.now().microsecondsSinceEpoch}';
      await txn.insert('sync_queue', {
        'id': queueId, 'uuid': 'uuid-$queueId', 'branch_id': 'branch-main',
        'table_name': 'vouchers', 'row_uuid': id, 'operation': 'INSERT',
        'payload_json': '{"voucher_id":"$id","voucher_no":"$voucherNo"}',
        'sync_version': 1, 'batch_id': null, 'status': 'PENDING',
        'queued_at': now, 'created_at': now, 'updated_at': now, 'is_deleted': 0,
      });
    });
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
    _partyId = widget.parties.isEmpty ? null : widget.parties.first.id;
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
        value: _type,
        decoration: const InputDecoration(labelText: 'نوع السند'),
        items: const [
          DropdownMenuItem(value: 'RECEIPT', child: Text('سند قبض')),
          DropdownMenuItem(value: 'PAYMENT', child: Text('سند صرف')),
        ],
        onChanged: (v) => setState(() => _type = v ?? 'RECEIPT'),
      ),
      DropdownButtonFormField<String>(
        value: _partyId,
        decoration: const InputDecoration(labelText: 'الطرف'),
        items: widget.parties.map((p) => DropdownMenuItem(value: p.id, child: Text(p.nameAr))).toList(),
        onChanged: (v) => setState(() => _partyId = v),
      ),
      TextField(controller: _amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ')),
      DropdownButtonFormField<String>(
        value: _method,
        decoration: const InputDecoration(labelText: 'طريقة الدفع'),
        items: const [
          DropdownMenuItem(value: 'CASH', child: Text('نقداً')),
          DropdownMenuItem(value: 'WALLET', child: Text('محفظة')),
          DropdownMenuItem(value: 'BANK', child: Text('بنك')),
        ],
        onChanged: (v) => setState(() {
          _method = v ?? 'CASH';
          _accountId = _method == 'CASH' ? 'cash-drawer' : 'wallet-jawali';
        }),
      ),
      if (_method == 'WALLET') ...[
        DropdownButtonFormField<String>(
          value: _accountId,
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
        (_method == 'WALLET' && _reference.text.trim().isEmpty)) return;
    Navigator.pop(context, _VoucherDraft(
      type: _type, partyId: _partyId!, cashAccountId: _accountId,
      amount: amount, method: _method, reference: _reference.text,
      description: _description.text.trim(),
    ));
  }
}