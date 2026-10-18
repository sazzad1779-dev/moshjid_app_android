import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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
/// Steps: configuration → network → auth → profile link → categories read →
/// profiles schema.
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

  // 6. Profiles schema. Without tools/donor_dedupe.sql the `profiles` table has
  // no phone/is_monthly/client_created_at, and every member push dies on a 42703
  // that pushProfiles swallows -- donors stay pending forever with no symptom.
  // Pull survives it (SyncService falls back to select *), so the roster looks
  // healthy while nothing uploads, which is exactly what makes this worth probing.
  try {
    await client
        .from('profiles')
        .select('id,full_name,phone,role,status,is_monthly,client_created_at')
        .limit(1);
    checks.add(const HealthCheck(
      'profiles schema',
      true,
      'match_key columns present',
    ));
  } on PostgrestException catch (e) {
    if (e.code == '42703' || e.message.contains('column')) {
      checks.add(const HealthCheck(
        'profiles schema',
        false,
        'Missing columns on profiles — run tools/donor_dedupe.sql in the '
            'Supabase SQL editor. Members cannot sync until it is applied.',
      ));
    } else {
      checks.add(HealthCheck(
          'profiles schema', false, 'SELECT blocked: ${_short(e)}'));
    }
    return SupabaseHealth(checks);
  } catch (e) {
    checks.add(
        HealthCheck('profiles schema', false, 'SELECT failed: ${_short(e)}'));
    return SupabaseHealth(checks);
  }

  // 7. Optional write probe (insert + immediate delete)
  if (testWrite) {
    // Donor insert first: this is the one that fails for a collector when
    // tools/collector_donor_write.sql has not been applied, and it is the
    // failure mode that leaves members stuck on "waiting to sync" with every
    // other signal green.
    try {
      const probeName = 'ZZ HEALTH CHECK probe';
      final now = DateTime.now().toUtc().toIso8601String();
      await client.from('profiles').insert({
        'id': const Uuid().v4(),
        'full_name': probeName,
        'role': 'member',
        'status': 'active',
        'client_created_at': now,
        'created_at': now,
        'updated_at': now,
      });
      try {
        final del = await client
            .from('profiles')
            .delete()
            .eq('full_name', probeName);
        checks.add(HealthCheck(
          'Donor write probe',
          true,
          'Insert + delete round-trip OK (${del.isEmpty ? '0' : '1'} row)',
        ));
      } catch (e) {
        checks.add(const HealthCheck(
          'Donor write probe',
          false,
          'Inserted but delete failed — remove the ZZ HEALTH CHECK probe row '
              'manually.',
        ));
      }
    } on PostgrestException catch (e) {
      final rls =
          e.code == '42501' || e.message.toLowerCase().contains('row-level security');
      checks.add(HealthCheck(
        'Donor write probe',
        false,
        rls
            ? 'profiles INSERT blocked by RLS — run '
                'tools/collector_donor_write.sql. Members cannot sync without it.'
            : 'INSERT blocked: ${_short(e)}',
      ));
    } catch (e) {
      checks.add(
          HealthCheck('Donor write probe', false, 'INSERT failed: ${_short(e)}'));
    }

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
