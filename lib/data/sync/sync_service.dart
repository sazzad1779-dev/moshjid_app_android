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

  /// Transactions left behind because their member is not on the server yet.
  /// Not a failure: they go up on the next sync, once the member lands.
  final int deferred;
  final String? error;

  const SyncResult({
    this.pulledProfiles = 0,
    this.pulledCategories = 0,
    this.pushedProfiles = 0,
    this.mergedProfiles = 0,
    this.pushed = 0,
    this.failed = 0,
    this.deferred = 0,
    this.error,
  });

  /// True when there was genuinely nothing to do, as opposed to a failure.
  ///
  /// [deferred] counts as quiet on purpose. A member that cannot be pushed
  /// holds its transactions every single cycle, and surfacing that from the
  /// five-minute timer would mean the same message forever. The pending badge
  /// already says how many are waiting.
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

  /// Resolves the signed-in user's `profiles.id`. Injectable for tests; the
  /// real service talks to [Supabase.instance].
  final AuthService _auth;

  SyncService(this.local, {SupabaseClient? client, AuthService? auth})
      : _injected = client,
        _auth = auth ?? AuthService();

  /// PostgREST caps a response; pull donors in pages rather than assuming the
  /// whole roster fits.
  static const _pageSize = 1000;

  SupabaseClient? get _client =>
      _injected ??
      (AppConfig.isSupabaseConfigured ? Supabase.instance.client : null);

  Future<bool> get isOnline async {
    final res = await Connectivity().checkConnectivity();
    return res.any(
      (r) =>
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet,
    );
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
      final ok = await _auth.ensureSignedIn();
      if (!ok) {
        return const SyncResult(
          error: 'Sync unavailable — service sign-in failed (offline or bad SERVICE_EMAIL/PASSWORD)',
        );
      }
    }
    if (!await isOnline) {
      return const SyncResult(error: 'Offline — kept locally');
    }

    // The entered_by cache is deliberately long-lived for offline writes, but
    // that means a re-linked or replaced profile would only be noticed after a
    // fresh sign-in. Re-resolve it once per sync so the next transaction is
    // written against the current server row.
    await _refreshCurrentUser();

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
      deferred: txnPush.deferred,
      // A member push failure is the more fundamental one: it also causes
      // transactions to be held back, so report it ahead of the transaction
      // error rather than losing it.
      error: donorPush.$3 ?? txnPush.error,
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
          .map(
            (e) => {
              'id': (e as Map)['id'],
              'name': e['name'],
              'type': e['type'],
            },
          )
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
  /// Only live donors are taken from the server. A soft-deleted row is ignored
  /// rather than cached as active: the roster is the thing the picker and the
  /// members tab read, and a tombstone must never reappear there. Rows this
  /// device deleted itself are preserved by [LocalDb.pruneCloudProfiles].
  ///
  /// Returns the number of donors now cached, or null on failure.
  Future<int?> pullProfiles() async {
    final client = _client;
    if (client == null) return null;
    try {
      final rows = (await _selectAllProfiles(client))
          .where((row) => row['is_deleted'] != true)
          .toList();

      final live = <String>{};
      for (final row in rows) {
        final remoteId = row['id'];
        if (remoteId is String && remoteId.isNotEmpty) live.add(remoteId);
        await local.upsertCloudProfile(row);
      }
      // Runs even when `rows` is empty. An empty roster is a real answer: every
      // donor that carries a server uuid has been removed there, and keeping
      // them visible would leave the picker showing people the server no longer
      // has. Pending local donors have no remote id and are never touched.
      await local.pruneCloudProfiles(live);
      return rows.length;
    } catch (_) {
      return null;
    }
  }

  /// Re-resolves the signed-in user's `profiles.id` for `entered_by`.
  ///
  /// [AuthService.resolveEnteredById] caches the id because transactions are
  /// written while offline, but the cache outlives server-side changes to the
  /// link. Refreshing here keeps new transactions pointed at the row that
  /// exists now. A failure is ignored on purpose: the cached id or the
  /// configured fallback is still usable, and sync must never throw.
  Future<void> _refreshCurrentUser() async {
    try {
      await _auth.resolveEnteredById(forceRefresh: true);
    } catch (_) {
      // Keep the cached/fallback id; sync continues either way.
    }
  }

  /// Reads the live roster, preferring the lean column list.
  ///
  /// Falls back to `*` when `phone`, `is_monthly` or `is_deleted` do not exist
  /// yet, which is the case until `tools/donor_dedupe.sql` and
  /// `tools/member_lifecycle.sql` have been run. Without this a missing
  /// migration would take the entire donor picker down rather than just the
  /// phone numbers. On that fallback path the caller's client-side
  /// `is_deleted` check is the only filter, since the column may be absent.
  Future<List<Map<String, dynamic>>> _selectAllProfiles(
    SupabaseClient client,
  ) async {
    const lean =
        'id,full_name,phone,role,status,is_monthly,is_deleted,client_created_at,created_at';
    try {
      return await _paged(
        (from, to) => client
            .from('profiles')
            .select(lean)
            // `IS NOT TRUE` also matches NULL, which a column added to an
            // existing table can hold. `= false` would silently skip every
            // such row and the pull would look like an empty roster.
            .not('is_deleted', 'is', true)
            .range(from, to),
      );
    } on PostgrestException catch (e) {
      // 42703 = undefined_column; PGRST204 is PostgREST's own "column not in
      // schema cache" before the statement reaches Postgres.
      if (e.code != '42703' && e.code != 'PGRST204' && !e.message.contains('column')) {
        rethrow;
      }
      return await _paged(
        (from, to) => client.from('profiles').select().range(from, to),
      );
    }
  }

  Future<List<Map<String, dynamic>>> _paged(
    Future<List<Map<String, dynamic>>> Function(int from, int to) page,
  ) async {
    final all = <Map<String, dynamic>>[];
    for (var from = 0; ; from += _pageSize) {
      final chunk = await page(from, from + _pageSize - 1);
      if (chunk.isEmpty) break;
      all.addAll(chunk);
      if (chunk.length < _pageSize) break;
    }
    return all;
  }

  /// Columns that a partially migrated server may not have yet.
  ///
  /// Ordered newest migration last, so each retry drops exactly the column that
  /// was rejected. A device whose app is newer than its database -- the normal
  /// state between a release and someone running the SQL -- still collects and
  /// uploads donors, minus the fields the server cannot accept. Without this
  /// the whole upsert fails on one unknown column and the donor is stranded.
  static const _optionalProfileCols = [
    'phone',
    'is_monthly',
    'client_created_at',
    'is_deleted',
  ];

  /// True when [e] means the server does not have a column we asked to send.
  ///
  /// Two different codes, and missing either one is a silent total failure:
  /// PostgREST checks the column against its schema cache *before* the statement
  /// reaches Postgres, so an absent column usually never arrives as `42703` at
  /// all. It comes back as `PGRST204` naming the column in plain English.
  static bool _isMissingColumn(PostgrestException e) =>
      e.code == '42703' || e.code == 'PGRST204';

  /// The column a missing-column error names, or null if it names something else.
  ///
  /// Postgres reports one missing column at a time (`column profiles.is_deleted
  /// does not exist`) even when several are absent, so the name has to be read
  /// off the error. Dropping columns in a fixed order instead would throw away
  /// fields the server is perfectly happy to accept -- a donor would upload
  /// without their phone number and nobody would notice.
  static String? _missingColumn(String message) {
    final postgrest = RegExp(r"Could not find the '([A-Za-z_]\w*)' column")
        .firstMatch(message);
    if (postgrest != null) return postgrest.group(1);
    final postgres = RegExp(
      r"column\s+(?:[A-Za-z_][\w]*\.)?'?([A-Za-z_]\w*)'?\s+does not exist",
    ).firstMatch(message);
    return postgres?.group(1);
  }

  /// Upserts one donor, shedding optional columns the server rejects.
  ///
  /// A permission or auth error is never swallowed here; only a genuinely
  /// missing column triggers a retry, and only that column is removed.
  Future<void> _upsertProfile(SupabaseClient client, Profile p) async {
    var payload = p.toSupabaseMap();
    for (var attempt = 0; attempt <= _optionalProfileCols.length; attempt++) {
      try {
        await client.from('profiles').upsert(payload, onConflict: 'id');
        return;
      } on PostgrestException catch (e) {
        if (!_isMissingColumn(e)) rethrow;
        final col = _missingColumn(e.message);
        // Only ever shed a column we were going to send anyway. Anything else
        // -- a required column, an unrecognised message -- is a real failure and
        // belongs to the caller's handler.
        if (col == null ||
            col == 'id' ||
            !_optionalProfileCols.contains(col) ||
            !payload.containsKey(col)) {
          rethrow;
        }
        payload = Map<String, dynamic>.of(payload)..remove(col);
      }
    }
    await client.from('profiles').upsert(payload, onConflict: 'id');
  }

  /// Soft-deletes one donor on the server.
  ///
  /// Kept separate from [_upsertProfile] so a delete can never be reduced to a
  /// successful no-op: there is no optional-column fallback here, and only the
  /// flag and timestamp are written, so the protected-column trigger has nothing
  /// to object to.
  Future<void> _markProfileDeleted(
    SupabaseClient client,
    String remoteId,
  ) async {
    await client.from('profiles').update({
      'is_deleted': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', remoteId);
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
  ///
  /// Returns `(created, merged, error)`. The third element is non-null when a
  /// push failed for a reason a retry cannot fix -- RLS or auth. Reporting it
  /// matters: without it a collector whose device cannot write `profiles` sees
  /// donors sit on "waiting to sync" forever with every other signal green.
  Future<(int, int, String?)> pushProfiles() async {
    final client = _client;
    if (client == null) return (0, 0, null);

    final pending = await local.pendingProfiles();
    if (pending.isEmpty) return (0, 0, null);

    var created = 0;
    var merged = 0;
    String? fatal;
    for (final p in pending) {
      try {
        final matchKey = p.matchKey;

        // An edit is already on the server under its own uuid, so it updates
        // that row in place. Deliberately skips the match_key lookup below:
        // asking "does anyone else have this identity?" and adopting their id
        // would re-point this donor at a stranger's row while the row we
        // actually edited sits on the server under a stale name.
        //
        // If the new identity genuinely collides with another donor, the
        // UNIQUE index raises and the catch block folds them together, which is
        // the same outcome as two devices racing on a new donor.
        if (p.remoteId != null) {
          if (p.isDeleted) {
            // A delete only needs the flag. Sending the whole row would re-run
            // the protected-column checks for no reason, and would let the
            // optional-column fallback silently drop `is_deleted` -- losing the
            // delete while the donor stays live on the server.
            await _markProfileDeleted(client, p.remoteId!);
          } else {
            await _upsertProfile(client, p);
          }
          await local.markProfileSynced(id: p.id, remoteId: p.remoteId!);
          if (p.isDeleted) {
            merged++;
          } else {
            created++;
          }
          continue;
        }

        // Ask first. This is the common case once another device or the Excel
        // import has already registered the donor.
        final existing = await _findRemoteByMatchKey(client, matchKey);
        if (existing != null) {
          // The row exists on the server under someone else's uuid, so there is
          // no row of ours to update. A pending delete still has to reach it,
          // or this device would hide the member while the server kept them.
          if (p.isDeleted) await _markProfileDeleted(client, existing);
          await local.markProfileSynced(id: p.id, remoteId: existing);
          merged++;
          continue;
        }

        // Upsert rather than insert so that a lost response on a previous
        // attempt is retried into the same row instead of colliding.
        await _upsertProfile(client, p);

        // Read back rather than assuming. The upsert reports success either
        // way, and when `profiles_first_wins` skips the row the server never
        // learns our local uuid at all. Trusting the status code here would
        // mark the donor synced against a uuid that does not exist.
        final canonical =
            await _findRemoteByMatchKey(client, matchKey) ?? p.pushId;
        await local.markProfileSynced(id: p.id, remoteId: canonical);
        if (canonical == p.pushId) {
          // The insert carried `is_deleted`, so a delete needs nothing more.
          created++;
        } else {
          // The server already had this donor under another id, so ours was
          // folded away. Same outcome as the early-exit branch above -- and a
          // pending delete has to be applied to the winner explicitly.
          if (p.isDeleted) await _markProfileDeleted(client, canonical);
          merged++;
        }
      } catch (e) {
        // Two devices inserting the same donor at the same instant: the
        // trigger skips the loser and the unique index raises. Whoever won is
        // the canonical row, so adopt them rather than retrying forever.
        if (_isDuplicateKey(e)) {
          final winner = await _findRemoteByMatchKey(client, p.matchKey);
          if (winner != null) {
            if (p.isDeleted) await _markProfileDeleted(client, winner);
            await local.markProfileSynced(id: p.id, remoteId: winner);
            merged++;
          }
        } else if (_isFatal(e) && fatal == null) {
          // RLS or auth. Retrying cannot help and will not report anything, so
          // surface it once and stop hammering the server.
          fatal = e.toString();
          break;
        }
        // Anything else (connectivity, transient) leaves the donor pending and
        // it is retried on the next sync.
      }
    }
    return (created, merged, fatal);
  }

  /// Finds the server uuid for a donor identity, or null when the server has
  /// never seen them.
  Future<String?> _findRemoteByMatchKey(
    SupabaseClient client,
    String matchKey,
  ) async {
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

  /// Whether [t] must wait for its donor to reach the server first.
  ///
  /// This is the invariant the whole ordering exists to protect, and it is not
  /// enough for [pushProfiles] to simply run first: that method reports
  /// completion even when every donor failed, because a failed push is
  /// indistinguishable from "nothing pending" in its return value. Without this
  /// check a transaction would go up with `member_id` omitted -- [buildPayload]
  /// strips the key rather than sending null -- get marked synced, and never be
  /// looked at again. The server would hold a member-less transaction
  /// permanently.
  ///
  /// A missing donor is deliberately *not* held. There is nothing to wait for:
  /// [LocalDb.pruneCloudProfiles] only ever deletes rows that already carry a
  /// remote id, so a locally created donor cannot vanish underneath us. A null
  /// donor therefore means a local id that never resolved, and holding forever
  /// would just strand the transaction instead of pushing it without a link.
  static bool isHeldForDonor(Txn t, Profile? donor) =>
      t.memberId != null && donor != null && donor.remoteId == null;

  /// Pulls transactions from the cloud (Supabase).
  ///
  /// Optional date range filtering. Returns all non-deleted transactions with
  /// joined category and donor info, paging past PostgREST's response limit.
  /// When offline or not configured, returns null. Query failures are allowed
  /// to reach the caller so the UI can report them instead of showing an empty
  /// success state.
  Future<List<Map<String, dynamic>>?> pullTransactions({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final client = _client;
    if (client == null) return null;
    if (client.auth.currentUser == null) {
      final ok = await AuthService().ensureSignedIn();
      if (!ok) return null;
    }
    if (!await isOnline) return null;

    final rows = await _paged((from, to) async {
      dynamic query = client
          .from('transactions')
          .select(
            'id, category_id, amount, payment_method, status, description, receipt_number, date, entered_by, member_id, donor_name, donor_phone, created_at, updated_at, is_deleted, transaction_categories(id, name, type)',
          )
          .eq('is_deleted', false);
      if (startDate != null) {
        query = query.gte('date', startDate.toIso8601String().split('T')[0]);
      }
      if (endDate != null) {
        query = query.lte('date', endDate.toIso8601String().split('T')[0]);
      }
      query = query
          .order('date', ascending: false)
          .order('created_at', ascending: false)
          .order('id', ascending: true)
          .range(from, to);
      final page = await query;
      return (page as List).cast<Map<String, dynamic>>();
    });
    // The server filters too; this keeps the contract explicit for a partial
    // migration or a proxy that ignores the query parameter.
    return rows.where((row) => row['is_deleted'] != true).toList();
  }

  /// Pushes pending transactions. Donors must already be pushed.
  Future<SyncResult> pushPending() async {
    final client = _client;
    if (client == null) {
      return const SyncResult(error: 'Supabase not configured (offline mode)');
    }
    final pending = await local.pendingTxns();
    if (pending.isEmpty) return const SyncResult();

    int ok = 0, fail = 0, held = 0;
    String? lastError;
    for (final t in pending) {
      try {
        final catId = await local.resolveCategoryId(t.category, t.type);

        // A donor's local id means nothing to the server; it wants the uuid.
        Profile? donor;
        if (t.memberId != null) {
          donor = await local.findProfileById(t.memberId!);
        }

        // The donor did not make it up this round. Leave `synced_at` alone so
        // the row stays in the queue and goes up right after the member lands.
        if (isHeldForDonor(t, donor)) {
          held++;
          continue;
        }

        // Upsert (not insert): covers new rows, edited rows, and
        // soft-deleted rows (is_deleted=true) in one path.
        await client
            .from('transactions')
            .upsert(
              buildPayload(t, categoryId: catId, donor: donor),
              onConflict: 'id',
            );
        await local.markSynced(t.id, DateTime.now());
        ok++;
      } catch (e) {
        fail++;
        lastError = e.toString();
        // stop on auth/RLS errors to avoid hammering; keep others for next run
        if (_isFatal(e)) break;
      }
    }
    return SyncResult(
      pushed: ok,
      failed: fail,
      deferred: held,
      error: lastError,
    );
  }

  /// Errors that will not fix themselves on a retry, so the queue should wait
  /// rather than spin.
  static bool _isFatal(Object e) {
    // A column the server does not have is a migration problem. Retrying the
    // same statement cannot succeed, so report it instead of leaving the row
    // pending forever with no explanation.
    if (e is PostgrestException && _isMissingColumn(e)) return true;
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
