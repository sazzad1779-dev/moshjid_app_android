import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/app_config.dart';
import '../data/auth/auth_service.dart';
import '../data/auth/health_check.dart';
import '../data/local/local_db.dart';
import '../data/models/txn.dart';
import '../data/sync/sync_service.dart';
import 'pin_gate.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _local = LocalDb();
  late final SyncService _sync;
  List<Txn> _txns = [];
  int _pending = 0;
  bool _syncing = false;
  String? _syncMsg;
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
    _reload();
    // Sync when connectivity changes (debounced by cooldown) + every 5 min.
    _connSub =
        Connectivity().onConnectivityChanged.listen((_) => _autoSync());
    _periodicTimer =
        Timer.periodic(_periodicSyncEvery, (_) => _autoSync());
    Future.delayed(const Duration(milliseconds: 500), _autoSync);
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _periodicTimer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final txns = await _local.listTxns();
    final pending = await _local.pendingCount();
    if (!mounted) return;
    setState(() {
      _txns = txns;
      _pending = pending;
    });
  }

  Future<void> _autoSync({bool force = false}) async {
    if (_syncing) return;
    if (!force &&
        _lastAutoSyncAt != null &&
        DateTime.now().difference(_lastAutoSyncAt!) < _autoSyncCooldown) {
      return;
    }
    _syncing = true;
    try {
      // Skip network entirely when there is nothing to push.
      if (await _local.pendingCount() == 0) {
        _lastAutoSyncAt = DateTime.now();
        await _sync.refreshCategories();
        return;
      }
      final r = await _sync.pushPending();
      _lastAutoSyncAt = DateTime.now();
      if ((r.pushed > 0 || r.failed > 0) && mounted) {
        setState(() => _syncMsg = _msg(r));
        await _reload();
      }
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      } else {
        _syncing = false;
      }
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
    final r = await _sync.pushPending();
    _lastAutoSyncAt = DateTime.now();
    await _reload();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncMsg = _msg(r);
    });
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_syncMsg ?? '')));
    }
  }

  double get _income => _txns
      .where((t) => t.type == 'income')
      .fold(0, (s, t) => s + t.amount);
  double get _expense => _txns
      .where((t) => t.type == 'expense')
      .fold(0, (s, t) => s + t.amount);

  Future<void> _openForm({Txn? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddTxnSheet(
        existing: existing,
        onSave: (t) async {
          await _local.insertTxn(t);
          await _reload();
          // best-effort immediate push; stays local if offline
          _autoSync(force: true);
        },
      ),
    );
    if (saved == true) await _reload();
  }

  Future<void> _viewTxn(Txn t) async {
    final fmt = NumberFormat('#,##0.##');
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 110,
                  child: Text(k,
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 12))),
              Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
            ],
          ),
        );
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${t.category} • ${fmt.format(t.amount)}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row('Type', t.type),
              row('Category', t.category),
              row('Amount', fmt.format(t.amount)),
              row('Method', t.paymentMethod),
              row('Date', DateFormat('yyyy-MM-dd').format(t.date)),
              row('Status', t.status),
              if (t.description != null)
                row('Note', t.description!),
              if (t.receiptNumber != null)
                row('Receipt', t.receiptNumber!),
              row('Sync', t.isSynced ? 'synced' : 'pending'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _openForm(existing: t);
            },
            child: const Text('Edit')),
        ],
      ),
    );
  }

  Future<void> _deleteTxn(Txn t) async {
    final fmt = NumberFormat('#,##0.##');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete transaction?'),
        content: Text(
            '${t.category} • ${fmt.format(t.amount)}\nIt will be removed here and on the server at the next sync.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'))
        ],
      ),
    );
    if (ok != true) return;
    await _local.softDelete(t.id);
    await _reload();
    _autoSync(force: true);
  }

  Future<void> _changePin() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Change PIN'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'New PIN (min 4 digits)', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().length >= 4) {
      await savePin(ctrl.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('PIN updated')));
      }
    }
  }

  Future<void> _checkConnection() async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        title: Text('Checking connection...'),
        content: SizedBox(
            height: 48, child: Center(child: CircularProgressIndicator())),
      ),
    );
    final health = await checkSupabaseHealth();
    if (!mounted) return;
    Navigator.pop(context); // close progress
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(health.ok ? 'All systems OK' : 'Connection issues'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(health.summary(),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              for (final c in health.checks)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(c.ok ? Icons.check_circle : Icons.error,
                          size: 18,
                          color: c.ok ? Colors.green : Colors.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${c.name}\n${c.detail}',
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.##');
    final balance = _income - _expense;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moshjid Transactions'),
        actions: [
          if (!AppConfig.isSupabaseConfigured)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(label: Text('offline-only'), visualDensity: VisualDensity.compact),
            ),
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                tooltip: 'Sync now',
                onPressed: _syncing ? null : _manualSync,
                icon: _syncing
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
              ),
              if (_pending > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: CircleAvatar(
                    radius: 9,
                    child: Text('$_pending',
                        style: const TextStyle(fontSize: 10)),
                  ),
                ),
            ],
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'pin') _changePin();
              if (v == 'health') _checkConnection();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pin', child: Text('Change PIN')),
              PopupMenuItem(
                  value: 'health', child: Text('Check connection')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _TotalsBar(income: _income, expense: _expense, balance: balance, fmt: fmt),
          if (_syncMsg != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(_syncMsg!, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          Expanded(
            child: _txns.isEmpty
                ? const Center(child: Text('No transactions yet.\nTap + to add.'))
                : RefreshIndicator(
                    onRefresh: () async {
                      await _manualSync();
                      await _reload();
                    },
                    child: ListView.builder(
                      itemCount: _txns.length,
                      itemBuilder: (_, i) {
                        final t = _txns[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: t.type == 'income'
                                ? Colors.green.shade100
                                : Colors.red.shade100,
                            child: Icon(
                              t.type == 'income' ? Icons.arrow_downward : Icons.arrow_upward,
                              color: t.type == 'income' ? Colors.green : Colors.red,
                            ),
                          ),
                          title: Text('${t.category} • ${fmt.format(t.amount)}'),
                          subtitle: Text(
                              '${DateFormat('yyyy-MM-dd').format(t.date)} • ${t.paymentMethod}${t.description != null ? ' • ${t.description}' : ''}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Chip(
                                label: Text(t.isSynced ? 'synced' : 'pending',
                                    style:
                                        const TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact,
                                backgroundColor: t.isSynced
                                    ? Colors.green.shade50
                                    : Colors.orange.shade100,
                              ),
                              PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'view') _viewTxn(t);
                                  if (v == 'edit') _openForm(existing: t);
                                  if (v == 'delete') _deleteTxn(t);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'view',
                                      child: Text('View')),
                                  PopupMenuItem(
                                      value: 'edit',
                                      child: Text('Edit')),
                                  PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete')),
                                ],
                              ),
                            ],
                          ),
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
}

class _TotalsBar extends StatelessWidget {
  final double income, expense, balance;
  final NumberFormat fmt;
  const _TotalsBar(
      {required this.income, required this.expense, required this.balance, required this.fmt});

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, double v, Color c) => Expanded(
          child: Column(
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text(fmt.format(v),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: c)),
            ],
          ),
        );
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            cell('Income', income, Colors.green),
            cell('Expense', expense, Colors.red),
            cell('Balance', balance, Colors.black87),
          ],
        ),
      ),
    );
  }
}

class AddTxnSheet extends StatefulWidget {
  final Future<void> Function(Txn) onSave;
  final Txn? existing;
  const AddTxnSheet({super.key, required this.onSave, this.existing});

  @override
  State<AddTxnSheet> createState() => _AddTxnSheetState();
}

class _AddTxnSheetState extends State<AddTxnSheet> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _desc = TextEditingController();
  final _receipt = TextEditingController();
  String _type = 'income';
  String _category = AppConfig.seedCategories['income']!.first;
  String _method = 'cash';
  DateTime _date = DateTime.now();
  bool _saving = false;
  List<String> _cats = AppConfig.seedCategories['income']!;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _type = ex.type;
      _category = ex.category;
      _method = ex.paymentMethod;
      _date = ex.date;
      _amount.text = ex.amount.toString();
      _desc.text = ex.description ?? '';
      _receipt.text = ex.receiptNumber ?? '';
      _cats = [...?AppConfig.seedCategories[_type]];
      if (!_cats.contains(_category)) _cats.add(_category);
    }
    _loadCats();
  }

  @override
  void dispose() {
    _amount.dispose();
    _desc.dispose();
    _receipt.dispose();
    super.dispose();
  }

  Future<void> _loadCats() async {
    // Prefer cached Supabase categories; fall back to seed.
    try {
      final db = LocalDb();
      final cached = await db.cachedCategories(_type);
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _cats = cached.map((e) => e['name'] as String).toList();
          // Never drop the row's own category (e.g. renamed remotely).
          if (!_cats.contains(_category)) _cats.add(_category);
        });
      }
    } catch (_) {}
  }

  void _onType(String? v) {
    if (v == null) return;
    setState(() {
      _type = v;
      _cats = AppConfig.seedCategories[_type] ?? [_category];
      _category = _cats.first;
    });
    _loadCats();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    String enteredBy;
    try {
      enteredBy = await AuthService().resolveEnteredById();
    } catch (_) {
      enteredBy = AppConfig.enteredById;
    }
    final amount = double.parse(_amount.text.trim());
    final ex = widget.existing;
    final t = ex == null
        ? Txn.create(
            type: _type,
            category: _category,
            amount: amount,
            paymentMethod: _method,
            enteredBy: enteredBy,
            status: AppConfig.defaultStatus,
            description: _desc.text,
            receiptNumber: _receipt.text.trim().isEmpty
                ? null
                : _receipt.text.trim(),
            date: _date,
          )
        : ex.applyEdit(
            type: _type,
            category: _category,
            amount: amount,
            paymentMethod: _method,
            status: ex.status,
            description: _desc.text,
            receiptNumber: _receipt.text.trim(),
            date: _date,
            enteredBy: enteredBy,
          );
    await widget.onSave(t);
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_isEditing ? 'Edit transaction' : 'New transaction',
                  style:
                      const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
                items: AppConfig.txnTypes
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: _onType,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration:
                    const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
                items: _cats.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Amount', border: OutlineInputBorder()),
                validator: Txn.validateAmount,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _method,
                decoration: const InputDecoration(
                    labelText: 'Payment method', border: OutlineInputBorder()),
                items: AppConfig.paymentMethods
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (v) => setState(() => _method = v ?? _method),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                        'Date: ${DateFormat('yyyy-MM-dd').format(_date)}'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 1)),
                        initialDate: _date,
                      );
                      if (d != null) setState(() => _date = d);
                    },
                    child: const Text('Pick date'),
                  ),
                ],
              ),
              TextFormField(
                controller: _desc,
                decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                    border: OutlineInputBorder()),
                maxLines: 2,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _receipt,
                decoration: const InputDecoration(
                    labelText: 'Receipt no (optional, auto if empty)',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving
                    ? 'Saving...'
                    : (_isEditing ? 'Save changes' : 'Save offline')),
              ),
              const SizedBox(height: 4),
              const Text('Saves locally first, syncs when online.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}