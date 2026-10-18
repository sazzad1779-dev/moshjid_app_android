import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/app_config.dart';
import '../auth/auth_service.dart';
import '../local/local_db.dart';

class SyncResult {
  final int pushed;
  final int failed;
  final String? error;
  const SyncResult({this.pushed = 0, this.failed = 0, this.error});
}

/// Pushes pending local txns to Supabase. Never blocks inserts.
class SyncService {
  final LocalDb local;
  SyncService(this.local);

  SupabaseClient? get _client =>
      AppConfig.isSupabaseConfigured ? Supabase.instance.client : null;

  Future<bool> get isOnline async {
    final res = await Connectivity().checkConnectivity();
    return res.any((r) =>
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet);
  }

  Future<void> refreshCategories() async {
    final client = _client;
    if (client == null) return;
    if (!await isOnline) return;
    try {
      final rows = await client
          .from('transaction_categories')
          .select('id,name,type')
          .eq('is_active', true);
      final cats = (rows as List)
          .map((e) => {
                'id': (e as Map)['id'],
                'name': e['name'],
                'type': e['type'],
              })
          .toList();
      if (cats.isNotEmpty) await local.cacheCategories(cats);
    } catch (_) {
      // stay offline-friendly: keep seed/cache
    }
  }

  Future<SyncResult> pushPending() async {
    final client = _client;
    if (client == null) {
      return const SyncResult(error: 'Supabase not configured (offline mode)');
    }
    if (client.auth.currentUser == null) {
      final ok = await AuthService().ensureSignedIn();
      if (!ok) {
        return const SyncResult(
            error: 'Sync unavailable — service sign-in failed (offline or bad SERVICE_EMAIL/PASSWORD)');
      }
    }
    if (!await isOnline) {
      return const SyncResult(error: 'Offline — kept locally');
    }
    final pending = await local.pendingTxns();
    int ok = 0, fail = 0;
    String? lastError;
    for (final t in pending) {
      try {
        final catId = await local.resolveCategoryId(t.category);
        // Upsert (not insert): covers new rows, edited rows, and
        // soft-deleted rows (is_deleted=true) in one path.
        await client.from('transactions').upsert(
              t.toSupabaseMap(
                resolvedCategoryId: catId ?? t.categoryId,
              ),
              onConflict: 'id',
            );
        await local.markSynced(t.id, DateTime.now());
        ok++;
      } catch (e) {
        fail++;
        lastError = e.toString();
        // stop on auth/RLS errors to avoid hammering; keep others for next run
        if (e.toString().contains('row-level security') ||
            e.toString().contains('JWT') ||
            e.toString().contains('401')) {
          break;
        }
      }
    }
    // best-effort category refresh after push
    await refreshCategories();
    return SyncResult(pushed: ok, failed: fail, error: lastError);
  }
}