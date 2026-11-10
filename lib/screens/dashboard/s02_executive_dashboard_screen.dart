import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/enterprise_dark_theme.dart';
import '../../core/pdf/receipt_and_ledger_pdf_builder.dart';
import '../../providers/supermarket_erp_provider.dart';

/// Presents branch KPIs, cash balances, inventory alerts and sync quota status.
class S02ExecutiveDashboardScreen extends StatefulWidget {
  const S02ExecutiveDashboardScreen({super.key});

  @override
  State<S02ExecutiveDashboardScreen> createState() => _S02ExecutiveDashboardScreenState();
}

class _S02ExecutiveDashboardScreenState extends State<S02ExecutiveDashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<SupermarketErpProvider>();
      provider.loadDashboard();
      provider.loadQuota();
    });
  }

  Future<void> _printDailyReport(SupermarketErpProvider provider) async {
    final data = provider.dashboard;
    await ReceiptAndLedgerPdfBuilder.previewDailySalesByPayment(
      date: DateTime.now(),
      totalsByMethod: provider.paymentTotalsByMethod,
      netSales: data['salesTotal'] ?? 0,
      invoiceCount: (data['salesCount'] ?? 0).toInt(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SupermarketErpProvider>(
      builder: (context, provider, _) {
        final data = provider.dashboard;
        final money = MoneyFormatter();
        return RefreshIndicator(
          onRefresh: () async {
            await provider.loadDashboard();
            await provider.loadQuota();
          },
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Text('لوحة التحكم التنفيذية', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              const Text('ملخص أداء الفرع — بيانات محلية محدثة'),
              const SizedBox(height: 10),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: () => _printDailyReport(provider),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('طباعة ملخص اليوم الرسمي PDF'),
                ),
              ),
              const SizedBox(height: 18),
              GridView.count(
                crossAxisCount: MediaQuery.sizeOf(context).width > 800 ? 4 : 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.45,
                children: [
                  _KpiCard(title: 'عدد الفواتير اليوم', value: (data['salesCount'] ?? 0).toStringAsFixed(0), icon: Icons.receipt_long, color: EnterpriseDarkTheme.primary),
                  _KpiCard(title: 'مبيعات اليوم', value: money.format(data['salesTotal'] ?? 0), icon: Icons.trending_up, color: EnterpriseDarkTheme.success),
                  _KpiCard(title: 'المتبقي على العملاء', value: money.format(data['creditTotal'] ?? 0), icon: Icons.people, color: EnterpriseDarkTheme.warning),
                  _KpiCard(title: 'المتبقي للموردين', value: money.format(data['supplierTotal'] ?? 0), icon: Icons.local_shipping, color: EnterpriseDarkTheme.danger),
                  _KpiCard(title: 'أصناف وصلت حد التنبيه', value: (data['stockAlerts'] ?? 0).toStringAsFixed(0), icon: Icons.warning_amber, color: EnterpriseDarkTheme.danger),
                ],
              ),
              const SizedBox(height: 18),
              Card(child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('أرصدة الصناديق والمحافظ', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Text(money.format(data['cashTotal'] ?? 0), style: Theme.of(context).textTheme.headlineMedium),
                  const Text('إجمالي الأرصدة المسجلة في الحسابات النقدية'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      _CashBalance(label: 'الصندوق والدرج', amount: data['cashDrawer'] ?? 0),
                      _CashBalance(label: 'جوالي', amount: data['jawali'] ?? 0),
                      _CashBalance(label: 'جيب', amount: data['jeeb'] ?? 0),
                      _CashBalance(label: 'فلوسك', amount: data['floosak'] ?? 0),
                      _CashBalance(label: 'كريمي', amount: data['kuraimi'] ?? 0),
                    ],
                  ),
                ]),
              )),
              const SizedBox(height: 12),
              Card(child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('مزامنة Firebase', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('الكتابات التقديرية اليوم: ${provider.quota?.writesUsed ?? 0}'),
                  LinearProgressIndicator(
                    value: (provider.quota?.writeUsageRatio ?? 0).clamp(0.0, 1.0).toDouble(),
                    color: EnterpriseDarkTheme.primary,
                    backgroundColor: EnterpriseDarkTheme.outline,
                  ),
                  const SizedBox(height: 6),
                  const Text('تستمر عمليات البيع محلياً حتى عند انقطاع الإنترنت.'),
                ]),
              )),
            ],
          ),
        );
      },
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.title, required this.value, required this.icon, required this.color});
  final String title, value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Icon(icon, color: color),
        Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        Text(title, style: Theme.of(context).textTheme.bodySmall),
      ]),
    ),
  );
}

class _CashBalance extends StatelessWidget {
  const _CashBalance({required this.label, required this.amount});

  final String label;
  final double amount;

  @override
  Widget build(BuildContext context) => Chip(
        avatar: const Icon(Icons.account_balance_wallet_outlined, size: 17),
        label: Text('$label: ${MoneyFormatter().format(amount)}'),
      );
}
