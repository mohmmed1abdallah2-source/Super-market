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
      label = 'المتبقي عليه ${money.format(net)}';
    } else if (net < -0.000001) {
      color = EnterpriseDarkTheme.success;
      label = 'المتبقي له ${money.format(net.abs())}';
    } else {
      color = EnterpriseDarkTheme.muted;
      label = 'مسدَّد (${money.format(0, includeCurrency: false)})';
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
    final ordered = entries.toList()
      ..sort((a, b) => (a['entry_date']?.toString() ?? '')
          .compareTo(b['entry_date']?.toString() ?? ''));
    var running = 0.0;
    final rows = <DataRow>[];
    for (final entry in ordered) {
      final alayh = (entry['alayh_amount'] as num?) ?? 0;
      final lah = (entry['lah_amount'] as num?) ?? 0;
      running += alayh - lah;
      final balanceLabel = running > 0.000001
          ? 'المتبقي عليه ${money.format(running)}'
          : running < -0.000001
              ? 'المتبقي له ${money.format(running.abs())}'
              : 'مسدَّد (0.00)';
      rows.add(DataRow(cells: [
        DataCell(Text(entry['entry_date']?.toString() ?? '')),
        DataCell(Text(entry['statement_ar']?.toString() ?? '')),
        DataCell(Text(entry['doc_id']?.toString() ?? '')),
        DataCell(Text(money.format(alayh), style: const TextStyle(color: EnterpriseDarkTheme.danger))),
        DataCell(Text(money.format(lah), style: const TextStyle(color: EnterpriseDarkTheme.success))),
        DataCell(Text(balanceLabel)),
      ]));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('التاريخ')),
          DataColumn(label: Text('البيان')),
          DataColumn(label: Text('المستند')),
          DataColumn(label: Text('عليه')),
          DataColumn(label: Text('له')),
          DataColumn(label: Text('المتبقي')),
        ],
        rows: rows,
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

/// A keyboard-aware bottom-sheet container for forms on small screens.
class KeyboardSafeModalSheet extends StatelessWidget {
  /// Creates a scrollable sheet that stays above the on-screen keyboard.
  const KeyboardSafeModalSheet({
    super.key,
    required this.child,
    this.maxHeightFactor = 0.92,
    this.padding = const EdgeInsets.all(12),
  });

  /// Sheet content.
  final Widget child;

  /// Maximum sheet height as a fraction of the available screen.
  final double maxHeightFactor;

  /// Inner sheet padding.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * maxHeightFactor;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              padding: padding,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
