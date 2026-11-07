import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/widgets/shared_widgets.dart';
import '../providers/supermarket_erp_provider.dart';
import 'dashboard/s02_executive_dashboard_screen.dart';
import 'pos/s03_supermarket_pos_screen.dart';
import 'catalog/s08_products_multi_unit_screen.dart';
import 'accounts/s19_parties_and_vouchers_screen.dart';

/// Main responsive navigation shell for the Arabic supermarket ERP.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  static const _destinations = [
    NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'الرئيسية'),
    NavigationDestination(icon: Icon(Icons.point_of_sale_outlined), selectedIcon: Icon(Icons.point_of_sale), label: 'الكاشير'),
    NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'الأصناف'),
    NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'الحسابات'),
  ];

  @override
  Widget build(BuildContext context) {
    final screens = const [
      S02ExecutiveDashboardScreen(),
      S03SupermarketPosScreen(),
      S08ProductsMultiUnitScreen(),
      S19PartiesAndVouchersScreen(),
    ];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        return Scaffold(
          appBar: AppBar(
            title: const Text('نظام إدارة السوبر ماركت'),
            actions: [
              Consumer<SupermarketErpProvider>(
                builder: (context, provider, _) => Padding(
                  padding: const EdgeInsetsDirectional.only(end: 12),
                  child: Center(child: FirebaseQuotaBadge(
                    writesUsed: provider.quota?.writesUsed ?? 0,
                    dailyLimit: provider.quota?.maxDailyWritesLimit ?? 18000,
                  )),
                ),
              ),
              IconButton(
                tooltip: 'تسجيل الخروج',
                onPressed: () => context.read<SupermarketErpProvider>().signOut(),
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: Row(children: [
            if (wide)
              NavigationRail(
                selectedIndex: _selectedIndex,
                onDestinationSelected: (value) => setState(() => _selectedIndex = value),
                labelType: NavigationRailLabelType.all,
                destinations: _destinations.map((item) => NavigationRailDestination(
                  icon: item.icon, selectedIcon: item.selectedIcon, label: Text(item.label),
                )).toList(),
              ),
            Expanded(child: IndexedStack(index: _selectedIndex, children: screens)),
          ]),
          bottomNavigationBar: wide ? null : NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (value) => setState(() => _selectedIndex = value),
            destinations: _destinations,
          ),
        );
      }),
    );
  }
}