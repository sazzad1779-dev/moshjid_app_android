import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../data/models/txn.dart';
import '../data/models/txn_summary.dart';
import '../data/repositories/txn_repository.dart';
import '../data/sync/sync_service.dart';
import 'app_scope.dart';
import 'dialogs/change_pin_dialog.dart';
import 'dialogs/connection_dialog.dart';
import 'sheets/txn_detail_sheet.dart';
import 'sheets/txn_entry_sheet.dart';
import 'widgets/totals_card.dart';
import 'widgets/txn_list_tile.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _pageSize = 50;

  /// Auto-sync at most once per minute; manual sync is always instant.
  static const _autoSyncCooldown = Duration(minutes: 1);
  static const _periodicSyncEvery = Duration(minutes: 5);

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();

  late final TxnRepository _repo;
  TxnFilter _filter = const TxnFilter.all();

  final List<Txn> _items = [];
  int _total = 0;
  TxnSummary _summary = TxnSummary.empty;
  int _pending = 0;
  bool _syncing = false;
  bool _loadingMore = false;
  bool _searching = false;
  String? _syncMsg;
  DateTime? _lastAutoSyncAt;

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _periodicTimer;

  @override
  void initState() {
    super.initState();
    _repo = AppScope.read(context);
    _scroll.addListener(_onScroll);
    _reload();
    // Sync when connectivity changes (debounced by cooldown) + every 5 min.
    _connSub = Connectivity().onConnectivityChanged.listen((_) => _autoSync());
    _periodicTimer = Timer.periodic(_periodicSyncEvery, (_) => _autoSync());
    Future.delayed(const Duration(milliseconds: 500), _autoSync);
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _periodicTimer?.cancel();
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ---- data ----

  /// Reloads the first page, the aggregate figures and the pending count.
  Future<void> _reload() async {
    final page = await _repo.load(filter: _filter, limit: _pageSize);
    final summary = await _repo.summary(filter: _filter);
    final pending = await _repo.pendingCount();
    if (!mounted) return;
    setState(() {
      _items
        ..clear()
        ..addAll(page.items);
      _total = page.total;
      _summary = summary;
      _pending = pending;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _items.length >= _total) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _repo.load(
        filter: _filter,
        limit: _pageSize,
        offset: _items.length,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
      });
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) _loadMore();
  }

  void _setType(String type) {
    setState(() => _filter = _filter.copyWith(type: type));
    _reload();
  }

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (!_searching && _filter.search.isNotEmpty) {
      _searchCtrl.clear();
      setState(() => _filter = _filter.copyWith(search: ''));
      _reload();
    }
  }

  void _onSearchChanged(String v) {
    setState(() => _filter = _filter.copyWith(search: v));
    _reload();
  }

  String get _caption {
    final parts = <String>[
      if (_filter.type != 'all') _filter.type,
      if (_filter.search.trim().isNotEmpty) '"${_filter.search.trim()}"',
    ];
    final scope = parts.isEmpty ? 'All transactions' : parts.join(' • ');
    return '$scope — $_total total';
  }

  // ---- sync ----

  Future<void> _autoSync({bool force = false}) async {
    if (_syncing) return;
    if (!force &&
        _lastAutoSyncAt != null &&
        DateTime.now().difference(_lastAutoSyncAt!) < _autoSyncCooldown) {
      return;
    }
    _syncing = true;
    try {
      // Skip the network entirely when there is nothing to push.
      if (await _repo.pendingCount() == 0) {
        _lastAutoSyncAt = DateTime.now();
        await _repo.refreshCategories();
        return;
      }
      final r = await _repo.syncNow();
      _lastAutoSyncAt = DateTime.now();
      if ((r.pushed > 0 || r.failed > 0) && mounted) {
        setState(() => _syncMsg = _msg(r));
        await _reload();
      }
    } finally {
      _syncing = false;
    }
  }

  String _msg(SyncResult r) {
    if (r.error != null && r.pushed == 0 && r.failed == 0) return r.error!;
    if (r.failed == 0) return 'Synced ${r.pushed} transaction(s)';
    return 'Synced ${r.pushed}, failed ${r.failed}: ${r.error ?? ''}';
  }

  Future<void> _manualSync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _syncMsg = null;
    });
    final r = await _repo.syncNow();
    _lastAutoSyncAt = DateTime.now();
    await _reload();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncMsg = _msg(r);
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_syncMsg ?? '')));
  }

  // ---- actions ----

  Future<void> _openForm({Txn? existing}) async {
    final saved = await showTxnEntrySheet(context, existing: existing);
    if (saved == null) return;
    await _reload();
    // best-effort immediate push; stays local if offline
    _autoSync(force: true);
  }

  Future<void> _deleteTxn(Txn t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete transaction?'),
        content: Text(
          '${t.category}\nIt will be removed here and on the '
          'server at the next sync.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.delete(t.id);
    await _reload();
    _autoSync(force: true);
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moshjid Transactions'),
        actions: [
          if (!AppConfig.isSupabaseConfigured)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(
                label: Text('offline-only'),
                visualDensity: VisualDensity.compact,
              ),
            ),
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search',
            onPressed: _toggleSearch,
            icon: Icon(_searching ? Icons.search_off : Icons.search),
          ),
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                tooltip: 'Sync now',
                onPressed: _syncing ? null : _manualSync,
                icon: _syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
              ),
              if (_pending > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: CircleAvatar(
                    radius: 9,
                    child: Text(
                      '$_pending',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                ),
            ],
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'pin') showChangePinDialog(context);
              if (v == 'health') showConnectionDialog(context);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pin', child: Text('Change PIN')),
              PopupMenuItem(value: 'health', child: Text('Check connection')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          TotalsCard(summary: _summary, caption: _caption),
          _typeTabs(),
          if (_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Category, note or receipt no',
                  border: OutlineInputBorder(),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
          if (_syncMsg != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(_syncMsg!, style: const TextStyle(fontSize: 12)),
            ),
          Expanded(
            child: _items.isEmpty
                ? const Center(
                    child: Text('No transactions yet.\nTap + to add.'),
                  )
                : RefreshIndicator(
                    onRefresh: _manualSync,
                    child: ListView.builder(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _items.length + (_loadingMore ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i >= _items.length) {
                          return const Padding(
                            padding: EdgeInsets.all(12),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final t = _items[i];
                        return TxnListTile(
                          txn: t,
                          onView: () => showTxnDetail(context, t),
                          onEdit: () => _openForm(existing: t),
                          onDelete: () => _deleteTxn(t),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openForm,
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
    );
  }

  Widget _typeTabs() => SizedBox(
    height: 40,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        for (final e in const [
          ('all', 'All'),
          ('income', 'Income'),
          ('expense', 'Expense'),
        ])
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(e.$2),
              selected: _filter.type == e.$1,
              onSelected: (_) => _setType(e.$1),
            ),
          ),
      ],
    ),
  );
}
