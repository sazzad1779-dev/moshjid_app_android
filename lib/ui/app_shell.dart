import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../data/local/local_db.dart';
import '../data/sync/sync_service.dart';
import 'members_page.dart';
import 'transactions_page.dart';

/// The app frame: two tabs and one sync engine.
///
/// Both tabs read from the same local database, so a member saved on the
/// members tab is visible to the transaction form on the next build without any
/// extra plumbing. Sync lives here rather than in a page because a member
/// pushed by one tab has to be on the server before the transaction that
/// references it goes up, and that ordering is the same regardless of which
/// tab triggered it.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _local = LocalDb.instance;
  late final SyncService _sync;

  /// Bumped after every write so the tabs rebuild from the database rather than
  /// from a copy each of them holds.
  int _revision = 0;

  int _tab = 0;
  bool _syncing = false;
  String? _syncMsg;
  int _pendingTxns = 0;
  int _pendingMembers = 0;

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _periodicTimer;
  DateTime? _lastAutoSyncAt;

  /// Auto-sync at most once per minute; manual sync is always instant.
  static const _autoSyncCooldown = Duration(minutes: 1);
  static const _periodicSyncEvery = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _sync = SyncService(_local);
    _refresh();
    // Sync when connectivity changes (debounced by cooldown) + every 5 min.
    _connSub = Connectivity().onConnectivityChanged.listen((_) => _autoSync());
    _periodicTimer = Timer.periodic(_periodicSyncEvery, (_) => _autoSync());
    Future.delayed(const Duration(milliseconds: 500), _autoSync);
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _periodicTimer?.cancel();
    super.dispose();
  }

  /// Re-reads the counters the app bar shows. Cheap enough to run after every
  /// write; the lists themselves reload themselves.
  Future<void> _refresh() async {
    final pending = await _local.pendingCount();
    final pendingMembers = await _local.pendingProfileCount();
    if (!mounted) return;
    setState(() {
      _pendingTxns = pending;
      _pendingMembers = pendingMembers;
      _revision++;
    });
  }

  Future<void> _autoSync({bool force = false}) async {
    if (_syncing) return;
    if (!force &&
        _lastAutoSyncAt != null &&
        DateTime.now().difference(_lastAutoSyncAt!) < _autoSyncCooldown) {
      return;
    }
    if (mounted) setState(() => _syncing = true);
    try {
      // Always a full round trip: the point is to bring the member roster down,
      // which is worth doing even when this device has nothing to push. The
      // cooldown above is what keeps that off every keystroke.
      final r = await _sync.sync();
      _lastAutoSyncAt = DateTime.now();
      if (r.isQuiet) return;
      await _refresh();
      if (mounted) setState(() => _syncMsg = _msg(r));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _msg(SyncResult r) {
    final bits = <String>[];
    if (r.pushedProfiles > 0) bits.add('${r.pushedProfiles} member(s)');
    if (r.mergedProfiles > 0) {
      bits.add('${r.mergedProfiles} member(s) matched an existing profile');
    }
    if (r.pushed > 0) bits.add('${r.pushed} transaction(s)');
    if (r.failed > 0) bits.add('${r.failed} failed');

    if (r.error != null && r.pushed == 0 && r.failed == 0 && bits.isEmpty) {
      return r.error!;
    }
    if (bits.isEmpty) return 'Already up to date';
    final head = bits.join(', ');
    return r.error == null ? 'Synced $head' : 'Synced $head — ${r.error}';
  }

  Future<void> _manualSync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _syncMsg = null;
    });
    final r = await _sync.sync(manual: true);
    _lastAutoSyncAt = DateTime.now();
    await _refresh();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncMsg = _msg(r);
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_syncMsg ?? '')));
  }

  /// Called by either tab after a write: refresh the counters and push
  /// immediately, so a collector with signal never waits for the next timer.
  Future<void> onDataChanged() async {
    await _refresh();
    await _autoSync(force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          // Keys stay stable and the pages reload on a revision change, so the
          // member tab keeps its scroll position and search text when a
          // transaction is added on the other tab.
          TransactionsPage(
            revision: _revision,
            syncing: _syncing,
            pendingTxns: _pendingTxns,
            pendingMembers: _pendingMembers,
            onSync: _manualSync,
            onDataChanged: onDataChanged,
            onOpenMembers: () => setState(() => _tab = 1),
          ),
          MembersPage(
            revision: _revision,
            onDataChanged: onDataChanged,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Transactions',
          ),
          NavigationDestination(
            icon: _pendingMembers > 0
                ? Badge.count(
                    count: _pendingMembers,
                    child: const Icon(Icons.groups_outlined),
                  )
                : const Icon(Icons.groups_outlined),
            selectedIcon: const Icon(Icons.groups),
            label: 'Members',
          ),
        ],
      ),
    );
  }
}