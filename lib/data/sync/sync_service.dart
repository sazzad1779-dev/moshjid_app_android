import 'dart:async';

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
  /// Rows per HTTP request. PostgREST accepts large bodies, but chunking
  /// keeps memory flat on low-end phones and avoids payload limits.
  static const chunkSize = 200;

  final LocalDb local;
  SyncService(this.local);

  SupabaseClient? get _client =>
      AppConfig.isSupabaseConfigured ? Supabase.instance.client : null;

  Future<bool> get isOnline async {
    final res = await Connectivity().checkConnectivity();
    return res.any(
      (r) =>
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet,
    );
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
          .map(
            (e) => {
              'id': (e as Map)['id'],
              'name': e['name'],
              'type': e['type'],
            },
          )
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
          error: 'Sync unavailable — service sign-in failed (offline or bad SERVICE_EMAIL/PASSWORD)',
        );
      }
    }
    if (!await isOnline) {
      return const SyncResult(error: 'Offline — kept locally');
    }

    final pending = await local.pendingTxns();
    if (pending.isEmpty) {
      await refreshCategories();
      return const SyncResult();
    }

    // One category lookup per type instead of one per row.
    final types = pending.map((t) => t.type).toSet();
    final catMaps = <String, Map<String, String>>{};
    for (final type in types) {
      catMaps[type] = await local.categoryIdMap(type);
    }

    final now = DateTime.now();
    int ok = 0;
    String? lastError;
    for (var i = 0; i < pending.length; i += chunkSize) {
      final chunk = pending.sublist(
        i,
        (i + chunkSize).clamp(0, pending.length),
      );
      final payload = chunk
          .map(
            (t) => t.toSupabaseMap(
              resolvedCategoryId: catMaps[t.type]?[t.category] ?? t.categoryId,
            ),
          )
          .toList(growable: false);
      try {
        // One upsert covers inserts, edits and soft-deletes (is_deleted).
        await client.from('transactions').upsert(payload, onConflict: 'id');
        await local.markManySynced(chunk.map((t) => t.id).toList(), now);
        ok += chunk.length;
      } catch (e) {
        lastError = e.toString();
        // Keep the chunk unsynced so it retries on the next run.
        if (_isFatal(e)) break;
      }
    }

    await refreshCategories();
    return SyncResult(
      pushed: ok,
      failed: pending.length - ok,
      error: lastError,
    );
  }

  /// Auth/RLS failures will not fix themselves by retrying; stop early
  /// instead of hammering the endpoint.
  static bool _isFatal(Object e) {
    final s = e.toString();
    return s.contains('row-level security') ||
        s.contains('JWT') ||
        s.contains('401') ||
        s.contains('403');
  }
}
