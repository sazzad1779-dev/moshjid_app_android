import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/app_config.dart';
import '../models/txn.dart';
import 'auth_service.dart';

/// One step of the health check.
class HealthCheck {
  final String name;
  final bool ok;
  final String detail;
  const HealthCheck(this.name, this.ok, this.detail);
}

/// Result of [checkSupabaseHealth]. [ok] is true only if every step passed.
class SupabaseHealth {
  final List<HealthCheck> checks;
  const SupabaseHealth(this.checks);

  bool get ok => checks.every((c) => c.ok);

  String summary() {
    final passed = checks.where((c) => c.ok).length;
    return '$passed/${checks.length} checks passed';
  }
}

/// Verifies the Supabase backend end-to-end using the hidden service account
/// from .env (SERVICE_EMAIL / SERVICE_PASSWORD).
///
/// Steps: configuration → network → auth → profile link → categories read.
/// With [testWrite] = true it additionally does one insert + delete round-trip
/// on `transactions` (sentinel row, removed immediately) to prove RLS allows
/// writes. Default is false (fully read-only, safe to run anytime).
Future<SupabaseHealth> checkSupabaseHealth({bool testWrite = false}) async {
  final checks = <HealthCheck>[];
  final auth = AuthService();

  // 1. Configuration
  if (!AppConfig.isSupabaseConfigured) {
    checks.add(
      const HealthCheck(
        'Configuration',
        false,
        'SUPABASE_URL / SUPABASE_ANON_KEY missing in .env',
      ),
    );
    return SupabaseHealth(checks);
  }
  checks.add(
    const HealthCheck('Configuration', true, 'URL + anon key present'),
  );
  if (!AppConfig.hasServiceCredentials) {
    checks.add(
      const HealthCheck(
        'Service credentials',
        false,
        'SERVICE_EMAIL / SERVICE_PASSWORD missing in .env',
      ),
    );
    return SupabaseHealth(checks);
  }
  checks.add(HealthCheck('Service credentials', true, AppConfig.serviceEmail));

  // 2. Network
  final conn = await Connectivity().checkConnectivity();
  final online = conn.any(
    (r) =>
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet,
  );
  if (!online) {
    checks.add(
      const HealthCheck('Network', false, 'No connectivity (offline)'),
    );
    return SupabaseHealth(checks);
  }
  checks.add(const HealthCheck('Network', true, 'Online'));

  // 3. Auth (service sign-in)
  SupabaseClient client;
  try {
    client = Supabase.instance.client;
  } catch (e) {
    checks.add(HealthCheck('Client', false, 'Supabase not initialized: $e'));
    return SupabaseHealth(checks);
  }
  final signedIn = await auth.ensureSignedIn();
  final user = client.auth.currentUser;
  if (!signedIn || user == null) {
    checks.add(
      const HealthCheck(
        'Authentication',
        false,
        'Service sign-in failed — wrong SERVICE_EMAIL/PASSWORD or email not confirmed',
      ),
    );
    return SupabaseHealth(checks);
  }
  checks.add(
    HealthCheck(
      'Authentication',
      true,
      'Signed in as ${user.email ?? user.id}',
    ),
  );

  // 4. Profile link (entered_by resolution)
  try {
    final profileId = await auth.resolveEnteredById();
    checks.add(HealthCheck('Profile link', true, 'profiles.id = $profileId'));
  } catch (e) {
    checks.add(
      HealthCheck(
        'Profile link',
        false,
        'No profiles row with auth_user_id = ${user.id}. Link it (see .env.example). $e',
      ),
    );
    return SupabaseHealth(checks);
  }

  // 5. Categories read
  try {
    final rows = await client
        .from('transaction_categories')
        .select('id')
        .eq('is_active', true)
        .limit(1);
    checks.add(
      HealthCheck(
        'Categories read',
        true,
        'OK (${(rows as List).length} sample row(s) returned)',
      ),
    );
  } catch (e) {
    checks.add(
      HealthCheck('Categories read', false, 'SELECT blocked: ${_short(e)}'),
    );
    return SupabaseHealth(checks);
  }

  // 6. Optional write probe (insert + immediate delete)
  if (testWrite) {
    try {
      final probe = Txn.create(
        type: 'other',
        category: 'Other Expense',
        amount: 1,
        paymentMethod: 'other',
        enteredBy: await auth.resolveEnteredById(),
        description: 'HEALTH_CHECK probe — safe to delete',
      );
      await client.from('transactions').insert(probe.toSupabaseMap());
      try {
        await client.from('transactions').delete().eq('id', probe.id);
        checks.add(
          const HealthCheck(
            'Write probe',
            true,
            'Insert + delete round-trip OK',
          ),
        );
      } catch (e) {
        checks.add(
          HealthCheck(
            'Write probe',
            false,
            'Inserted but delete failed — remove id ${probe.id} manually. ${_short(e)}',
          ),
        );
      }
    } catch (e) {
      checks.add(
        HealthCheck(
          'Write probe',
          false,
          'INSERT blocked (RLS?): ${_short(e)}',
        ),
      );
    }
  }

  return SupabaseHealth(checks);
}

String _short(Object e) {
  final s = e.toString();
  return s.length > 220 ? '${s.substring(0, 220)}…' : s;
}
