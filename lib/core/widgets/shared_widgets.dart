import 'package:flutter/material.dart';
import '../theme/enterprise_dark_theme.dart';

/// Displays a party's balance using the approved Arabic wording and colors only.
class PartyBalanceChip extends StatelessWidget {
  const PartyBalanceChip({
    super.key,
    required this.totalAlayh,
    required this.totalLah,
    this.formatter,
  });

  final num totalAlayh;
  final num totalLah;
  final MoneyFormatter? formatter;

  @override
  Widget build(BuildContext context) {
    final money = formatter ?? MoneyFormatter();
    final net = totalAlayh - totalLah;
    final Color color;
    final String label;
    if (net > 0.000001) {
      color = EnterpriseDarkTheme.danger;
      label = 'المتبقي عليه \${money.format(net)}';
    } else if (net < -0.000001) {
      color = EnterpriseDarkTheme.success;
      label = 'المتبقي له \${money.format(net.abs())}';
    } else {
      color = EnterpriseDarkTheme.muted;
      label = 'مسدَّد (\${money.format(0)})';
    }
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// Renders party ledger rows without exposing internal accounting terminology.
class LahAlayhTable extends StatelessWidget {
  const LahAlayhTable({super.key, required this.entries, this.formatter});

  final List<Map<String, Object?>> entries;
  final MoneyFormatter? formatter;

  @override
  Widget build(BuildContext context) {
    final money = formatter ?? MoneyFormatter();
    if (entries.isEmpty) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('لا توجد حركات مسجلة'),
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('التاريخ')),
          DataColumn(label: Text('البيان')),
          DataColumn(label: Text('عليه')),
          DataColumn(label: Text('له')),
        ],
        rows: entries.map((entry) {
          final date = entry['entry_date']?.toString() ?? '';
          final statement = entry['statement_ar']?.toString() ?? '';
          final alayh = (entry['alayh_amount'] as num?) ?? 0;
          final lah = (entry['lah_amount'] as num?) ?? 0;
          return DataRow(cells: [
            DataCell(Text(date)),
            DataCell(Text(statement)),
            DataCell(Text(money.format(alayh), style: const TextStyle(color: EnterpriseDarkTheme.danger))),
            DataCell(Text(money.format(lah), style: const TextStyle(color: EnterpriseDarkTheme.success))),
          ]);
        }).toList(),
      ),
    );
  }
}

/// Provides a reusable manager-PIN confirmation dialog.
class ManagerPinDialog {
  ManagerPinDialog._();

  /// Prompts for a PIN and returns it; null means the dialog was cancelled.
  static Future<String?> show(BuildContext context, {String title = 'تأكيد صلاحية المدير'}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'رمز المدير'),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()), child: const Text('تأكيد')),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}

/// Captures the transaction reference required for wallet payments.
class WalletRefField extends StatelessWidget {
  const WalletRefField({super.key, required this.controller, this.validator});

  final TextEditingController controller;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    textDirection: TextDirection.ltr,
    decoration: const InputDecoration(
      labelText: 'رقم إشعار المحفظة',
      hintText: 'أدخل رقم العملية',
      prefixIcon: Icon(Icons.receipt_long),
    ),
    validator: validator ?? (value) =>
        (value == null || value.trim().isEmpty) ? 'رقم إشعار المحفظة مطلوب' : null,
  );
}

/// Shows estimated daily Firebase usage and the local safety ceiling.
class FirebaseQuotaBadge extends StatelessWidget {
  const FirebaseQuotaBadge({
    super.key,
    required this.writesUsed,
    this.dailyLimit = 18000,
  });

  final int writesUsed;
  final int dailyLimit;

  @override
  Widget build(BuildContext context) {
    final safeLimit = dailyLimit <= 0 ? 18000 : dailyLimit;
    final ratio = (writesUsed / safeLimit).clamp(0.0, 1.0);
    final color = ratio >= 0.95
        ? EnterpriseDarkTheme.danger
        : ratio >= 0.8
            ? EnterpriseDarkTheme.warning
            : EnterpriseDarkTheme.success;
    return Tooltip(
      message: 'استهلاك الكتابات التقديري لهذا اليوم',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_sync, size: 17, color: color),
          const SizedBox(width: 7),
          Text('$writesUsed / $safeLimit', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }
}