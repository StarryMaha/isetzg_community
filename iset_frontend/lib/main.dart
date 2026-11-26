import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/api_client.dart';
import 'state/auth_provider.dart';
import 'state/chat_provider.dart';
import 'state/p2p_provider.dart';
import 'screens/shell.dart';
import 'screens/login_screen.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(IsetApp(prefs: prefs));
}

class IsetApp extends StatelessWidget {
  final SharedPreferences prefs;
  const IsetApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>(create: (_) => ApiClient()),
        ChangeNotifierProvider<AuthProvider>(
          create: (ctx) {
            final auth = AuthProvider(ctx.read<ApiClient>(), prefs);
            Future.microtask(auth.restore);
            return auth;
          },
        ),
        ChangeNotifierProvider<P2PProvider>(
          create: (_) => P2PProvider(prefs: prefs),
        ),
        ChangeNotifierProxyProvider<AuthProvider, ChatProvider>(
          create: (ctx) => ChatProvider(
            ctx.read<ApiClient>(),
            prefs,
            p2p: ctx.read<P2PProvider>(),
          ),
          update: (ctx, auth, chat) => chat!..update(auth),
        ),
      ],
      child: MaterialApp(
        title: 'ISET Community',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const SessionGate(),
      ),
    );
  }
}

/// Switches between login, guest mode and the authenticated app based on the
/// persisted session restored at startup.
class SessionGate extends StatelessWidget {
  const SessionGate({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.watch<AuthProvider>().status;
    switch (status) {
      case AuthStatus.initializing:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case AuthStatus.authenticated:
        return const AppShell(isGuest: false);
      case AuthStatus.guest:
        return const AppShell(isGuest: true);
      case AuthStatus.unauthenticated:
        return const LoginScreen();
    }
  }
}
