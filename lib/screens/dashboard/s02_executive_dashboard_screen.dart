import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/enterprise_dark_theme.dart';
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
                  _KpiCard(title: 'المبالغ المتبقية على العملاء', value: money.format(data['creditTotal'] ?? 0), icon: Icons.people, color: EnterpriseDarkTheme.warning),
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
                ]),
              )),
              const SizedBox(height: 12),
              Card(child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('مزامنة Firebase', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('الكتابات التقديرية اليوم: \${provider.quota?.writesUsed ?? 0}'),
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