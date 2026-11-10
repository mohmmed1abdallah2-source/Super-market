import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'core/theme/enterprise_dark_theme.dart';
import 'data/database/database_helper.dart';
import 'providers/pos_and_catalog_provider.dart';
import 'providers/pos_and_ledger_provider.dart';
import 'providers/supermarket_erp_provider.dart';
import 'screens/app_shell.dart';

/// Initializes local storage before launching the Arabic RTL application.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.instance.database;
  runApp(const SupermarketErpApp());
}

/// Registers providers, theme and Arabic localization delegates.
class SupermarketErpApp extends StatelessWidget {
  const SupermarketErpApp({super.key});

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => SupermarketErpProvider()),
      ChangeNotifierProvider(create: (_) => PosAndLedgerProvider()),
      ChangeNotifierProvider(create: (_) => PosAndCatalogProvider()..createTab()),
    ],
    child: MaterialApp(
      title: 'Global Enterprise Supermarket ERP',
      debugShowCheckedModeBanner: false,
      theme: EnterpriseDarkTheme.build(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _LoginGate(),
    ),
  );
}

class _LoginGate extends StatefulWidget {
  const _LoginGate();
  @override
  State<_LoginGate> createState() => _LoginGateState();
}

class _LoginGateState extends State<_LoginGate> {
  final _username = TextEditingController(text: 'admin');
  final _password = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Consumer<SupermarketErpProvider>(
    builder: (context, provider, _) {
      if (provider.currentUser != null) return const AppShell();
      return Scaffold(
        body: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(margin: const EdgeInsets.all(20), child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.storefront, size: 54, color: EnterpriseDarkTheme.primary),
              const SizedBox(height: 12),
              Text('نظام إدارة السوبر ماركت', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 20),
              TextField(controller: _username,
                decoration: const InputDecoration(labelText: 'اسم المستخدم', prefixIcon: Icon(Icons.person))),
              const SizedBox(height: 12),
              TextField(controller: _password, obscureText: true,
                onSubmitted: (_) => _login(provider),
                decoration: const InputDecoration(labelText: 'كلمة المرور', prefixIcon: Icon(Icons.lock))),
              if (provider.error != null) ...[
                const SizedBox(height: 10),
                Text(provider.error!, style: const TextStyle(color: EnterpriseDarkTheme.danger)),
              ],
              const SizedBox(height: 18),
              SizedBox(width: double.infinity, child: FilledButton(
                onPressed: _submitting ? null : () => _login(provider),
                child: _submitting ? const CircularProgressIndicator() : const Text('تسجيل الدخول'),
              )),
              const SizedBox(height: 10),
              const Text('حساب التطوير الأولي: admin — كلمة المرور: 123456',
                textAlign: TextAlign.center,
                style: TextStyle(color: EnterpriseDarkTheme.muted, fontSize: 12)),
            ]),
          )),
        )),
      );
    },
  );

  Future<void> _login(SupermarketErpProvider provider) async {
    setState(() => _submitting = true);
    await provider.signIn(_username.text, _password.text);
    if (mounted) setState(() => _submitting = false);
  }
}