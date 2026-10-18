import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/app_config.dart';
import '../auth/auth_service.dart';
import '../local/local_db.dart';
import '../models/profile.dart';
import '../models/txn.dart';

class SyncResult {
  final int pulledProfiles;
  final int pulledCategories;
  final int pushedProfiles;
  final int mergedProfiles;
  final int pushed;
  final int failed;
  final String? error;

  const SyncResult({
    this.pulledProfiles = 0,
    this.pulledCategories = 0,
    this.pushedProfiles = 0,
    this.mergedProfiles = 0,
    this.pushed = 0,
    this.failed = 0,
    this.error,
  });

  /// True when there was genuinely nothing to do, as opposed to a failure.
  bool get isQuiet =>
      error == null &&
      pushed == 0 &&
      pushedProfiles == 0 &&
      mergedProfiles == 0 &&
      pulledProfiles == 0 &&
      pulledCategories == 0;
}

/// Moves data between the device and Supabase.
///
/// Ordering is the whole point: a transaction carries a `member_id` that points
/// at a donor, so [pushProfiles] always runs to completion before
/// [pushPending] sends a single transaction. Otherwise the server would
/// receive a reference to a profile that does not exist there yet.
///
/// Nothing here is allowed to throw. Every path either makes progress or
/// records an error string, because sync runs from a timer and a connectivity
/// callback where an unhandled exception would be invisible.
class SyncService {
  final LocalDb local;

  /// Explicit client, used by tests. When null the client comes from
  /// [AppConfig] and [Supabase.instance] as normal.
  final SupabaseClient? _injected;

  SyncService(this.local, {SupabaseClient? client}) : _injected = client;

  /// PostgREST caps a response; pull donors in pages rather than assuming the
  /// whole roster fits.
  static const _pageSize = 1000;

  SupabaseClient? get _client =>
      _injected ??
      (AppConfig.isSupabaseConfigured ? Supabase.instance.client : null);

  Future<bool> get isOnline async {
    final res = await Connectivity().checkConnectivity();
    return res.any((r) =>
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet);
  }

  /// Full sync: pull reference data, push local work, pull reference data again.
  ///
  /// The second pull is not redundant. Pushing a donor can reveal that the
  /// server already had somebody with the same identity under a different
  /// spelling, and picking up the server's canonical version is what stops the
  /// same person showing up twice in the picker.
  Future<SyncResult> sync({bool manual = false}) async {
    final client = _client;
    if (client == null) {
      return const SyncResult(error: 'Supabase not configured (offline mode)');
    }
    if (client.auth.currentUser == null) {
      final ok = await AuthService().ensureSignedIn();
      if (!ok) {
        return const SyncResult(
            error:
                'Sync unavailable — service sign-in failed (offline or bad SERVICE_EMAIL/PASSWORD)');
      }
    }
    if (!await isOnline) {
      return const SyncResult(error: 'Offline — kept locally');
    }

    final cats = await refreshCategories();
    var profiles = await pullProfiles();

    final donorPush = await pushProfiles();
    final txnPush = await pushPending();

    // A merge means the server settled on a different spelling or id for a
    // donor we hold, so pick up its canonical version. Only after a merge --
    // re-downloading the whole roster on every sync would be wasteful.
    if (donorPush.$2 > 0) {
      await refreshCategories();
      profiles = await pullProfiles() ?? profiles;
    }

    return SyncResult(
      pulledProfiles: profiles ?? 0,
      pulledCategories: cats ?? 0,
      pushedProfiles: donorPush.$1,
      mergedProfiles: donorPush.$2,
      pushed: txnPush.pushed,
      failed: txnPush.failed,
      error: txnPush.error,
    );
  }

  /// Replaces the category cache with the server's active categories.
  ///
  /// Returns how many rows landed, or null when the pull failed -- a stale
  /// cache is better than an empty one.
  Future<int?> refreshCategories() async {
    final client = _client;
    if (client == null) return null;
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
      if (cats.isEmpty) return null;
      await local.cacheCategories(cats);
      return cats.length;
    } catch (_) {
      // stay offline-friendly: keep whatever cache we already have
      return null;
    }
  }

  /// Downloads the donor roster so the picker works offline.
  ///
  /// Returns the number of donors now cached, or null on failure.
  Future<int?> pullProfiles() async {
    final client = _client;
    if (client == null) return null;
    try {
      final rows = await _selectAllProfiles(client);
      if (rows.isEmpty) return null;

      final live = <String>{};
      for (final row in rows) {
        final remoteId = row['id'];
        if (remoteId is String && remoteId.isNotEmpty) live.add(remoteId);
        await local.upsertCloudProfile(row);
      }
      await local.pruneCloudProfiles(live);
      return rows.length;
    } catch (_) {
      return null;
    }
  }

  /// Reads the whole roster, preferring the lean column list.
  ///
  /// Falls back to `*` when `phone` or `is_monthly` do not exist yet, which is
  /// the case until `tools/donor_dedupe.sql` has been run. Without this a
  /// missing migration would take the entire donor picker down rather than
  /// just the phone numbers.
  Future<List<Map<String, dynamic>>> _selectAllProfiles(
      SupabaseClient client) async {
    const lean =
        'id,full_name,phone,role,status,is_monthly,client_created_at,created_at';
    try {
      return await _paged(
          (from, to) => client.from('profiles').select(lean).range(from, to),
      );
    } on PostgrestException catch (e) {
      // 42703 = undefined_column
      if (e.code != '42703' && !e.message.contains('column')) rethrow;
      return await _paged(
          (from, to) => client.from('profiles').select().range(from, to));
    }
  }

  Future<List<Map<String, dynamic>>> _paged(
    Future<List<Map<String, dynamic>>> Function(int from, int to) page,
  ) async {
    final all = <Map<String, dynamic>>[];
    for (var from = 0;; from += _pageSize) {
      final chunk = await page(from, from + _pageSize - 1);
      if (chunk.isEmpty) break;
      all.addAll(chunk);
      if (chunk.length < _pageSize) break;
    }
    return all;
  }

  /// Pushes donors this device created offline.
  ///
  /// Returns `(created, merged)`:
  ///
  ///  * created -- the server did not know this donor; it was inserted under
  ///    the local id, so the two agree from the first upload.
  ///  * merged -- the server already had this donor, most likely created by
  ///    another device or from the Excel import. This device's row adopts the
  ///    server's uuid instead of inserting a twin, and the transactions
  ///    pointing at it need no changes because they reference the local id.
  ///
  /// Ordered oldest first so that when several devices have been offline with
  /// the same new donor, the earliest spelling is the one that survives.
  Future<(int, int)> pushProfiles() async {
    final client = _client;
    if (client == null) return (0, 0);

    final pending = await local.pendingProfiles();
    if (pending.isEmpty) return (0, 0);

    var created = 0;
    var merged = 0;
    for (final p in pending) {
      try {
        final matchKey = p.matchKey;

        // Ask first. This is the common case once another device or the Excel
        // import has already registered the donor.
        final existing =
            await _findRemoteByMatchKey(client, matchKey);
        if (existing != null) {
          await local.markProfileSynced(id: p.id, remoteId: existing);
          merged++;
          continue;
        }

        // Upsert rather than insert so that a lost response on a previous
        // attempt is retried into the same row instead of colliding.
        await client.from('profiles').upsert(p.toSupabaseMap(),
            onConflict: 'id');

        // Read back rather than assuming. The upsert reports success either
        // way, and when `profiles_first_wins` skips the row the server never
        // learns our local uuid at all. Trusting the status code here would
        // mark the donor synced against a uuid that does not exist.
        final canonical =
            await _findRemoteByMatchKey(client, matchKey) ?? p.pushId;
        await local.markProfileSynced(id: p.id, remoteId: canonical);
        if (canonical == p.pushId) {
          created++;
        } else {
          // The server already had this donor under another id, so ours was
          // folded away. Same outcome as the early-exit branch above.
          merged++;
        }
      } catch (e) {
        // Two devices inserting the same donor at the same instant: the
        // trigger skips the loser and the unique index raises. Whoever won is
        // the canonical row, so adopt them rather than retrying forever.
        if (_isDuplicateKey(e)) {
          final winner = await _findRemoteByMatchKey(client, p.matchKey);
          if (winner != null) {
            await local.markProfileSynced(id: p.id, remoteId: winner);
            merged++;
          }
        }
        // Anything else (RLS, auth, connectivity) leaves the donor pending and
        // it is retried on the next sync.
      }
    }
    return (created, merged);
  }

  /// Finds the server uuid for a donor identity, or null when the server has
  /// never seen them.
  Future<String?> _findRemoteByMatchKey(
      SupabaseClient client, String matchKey) async {
    try {
      final rows = await client
          .from('profiles')
          .select('id')
          .eq('match_key', matchKey)
          .limit(1);
      if (rows.isEmpty) return null;
      return (rows.first as Map)['id'] as String?;
    } catch (_) {
      // `match_key` is a generated column from donor_dedupe.sql. Without it
      // there is no way to ask, and pushing blind is worse than waiting.
      return null;
    }
  }

  /// Builds the `transactions` upsert body.
  ///
  /// Extracted from [pushPending] so the rules that matter can be tested
  /// without a server:
  ///
  ///  * `member_id` is the donor's *server* uuid, never the local id.
  ///  * When the donor cannot be resolved, the key is **omitted**, not sent as
  ///    null. This is an upsert, so a null would overwrite and destroy a value
  ///    the server already holds for an already-synced row.
  ///  * `donor_name` / `donor_phone` come from the donor record, so after a
  ///    merge the transaction carries the spelling the server settled on rather
  ///    than whatever was typed on this device.
  static Map<String, dynamic> buildPayload(
    Txn t, {
    String? categoryId,
    Profile? donor,
  }) {
    final memberId = donor?.remoteId;
    final payload = t.toSupabaseMap(
      resolvedCategoryId: categoryId ?? t.categoryId,
      resolvedMemberId: memberId,
    );
    if (memberId == null) payload.remove('member_id');
    if (donor != null) {
      payload['donor_name'] = donor.fullName;
      payload['donor_phone'] = donor.phone;
    }
    return payload;
  }

  /// Pushes pending transactions. Donors must already be pushed.
  Future<SyncResult> pushPending() async {
    final client = _client;
    if (client == null) {
      return const SyncResult(error: 'Supabase not configured (offline mode)');
    }
    final pending = await local.pendingTxns();
    if (pending.isEmpty) return const SyncResult();

    int ok = 0, fail = 0;
    String? lastError;
    for (final t in pending) {
      try {
        final catId = await local.resolveCategoryId(t.category, t.type);

        // A donor's local id means nothing to the server; it wants the uuid.
        Profile? donor;
        if (t.memberId != null) {
          donor = await local.findProfileById(t.memberId!);
        }

        // Upsert (not insert): covers new rows, edited rows, and
        // soft-deleted rows (is_deleted=true) in one path.
        await client
            .from('transactions')
            .upsert(buildPayload(t, categoryId: catId, donor: donor),
                onConflict: 'id');
        await local.markSynced(t.id, DateTime.now());
        ok++;
      } catch (e) {
        fail++;
        lastError = e.toString();
        // stop on auth/RLS errors to avoid hammering; keep others for next run
        if (_isFatal(e)) break;
      }
    }
    return SyncResult(pushed: ok, failed: fail, error: lastError);
  }

  /// Errors that will not fix themselves on a retry, so the queue should wait
  /// rather than spin.
  static bool _isFatal(Object e) {
    final s = e.toString();
    return s.contains('row-level security') ||
        s.contains('JWT') ||
        s.contains('401') ||
        s.contains('403');
  }

  /// Postgres 23505, or the PostgREST error for a unique violation.
  ///
  /// The trigger path reports success with an empty body instead of erroring,
  /// which is why [pushProfiles] re-reads by match_key after a conflict rather
  /// than trusting the status code.
  static bool _isDuplicateKey(Object e) {
    if (e is PostgrestException) return e.code == '23505';
    return e.toString().contains('23505') ||
        e.toString().contains('duplicate key');
  }
}