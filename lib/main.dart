import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_config.dart';
import 'data/auth/auth_service.dart';
import 'ui/home_page.dart';
import 'ui/pin_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    debugPrint('No .env found ($e) — falling back to --dart-define');
  }
  if (AppConfig.isSupabaseConfigured) {
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        // ignore: deprecated_member_use
        anonKey: AppConfig.supabaseAnonKey,
      );
      // Silent service sign-in (PIN stays the only visible gate).
      // Failure is fine here — sync retries it later when online.
      final ok = await AuthService().ensureSignedIn();
      debugPrint(
        ok ? 'Service session ready' : 'Service sign-in pending (offline or missing SERVICE_EMAIL/PASSWORD)',
      );
    } catch (e) {
      debugPrint('Supabase init failed (offline mode): $e');
    }
  } else {
    debugPrint(
      'Supabase not configured — running offline-only. '
      'Set SUPABASE_URL / SUPABASE_ANON_KEY in .env or --dart-define.',
    );
  }
  runApp(const MoshjidApp());
}

class MoshjidApp extends StatefulWidget {
  const MoshjidApp({super.key});

  @override
  State<MoshjidApp> createState() => _MoshjidAppState();
}

class _MoshjidAppState extends State<MoshjidApp> {
  bool _unlocked = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Moshjid Transactions',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      // PIN is the only visible gate; Supabase auth happens silently.
      home: _unlocked
          ? const HomePage()
          : PinGate(onUnlocked: () => setState(() => _unlocked = true)),
    );
  }
}
