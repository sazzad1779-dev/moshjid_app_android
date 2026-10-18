import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/app_config.dart';
import '../data/auth/health_check.dart';
import '../data/local/local_db.dart';
import '../data/models/txn.dart';
import 'pin_gate.dart';
import 'widgets/txn_form_sheet.dart';
import 'widgets/type_selector.dart';

/// The transaction ledger: totals, search, and the list of entries.
///
/// Reads the local database on every build it is asked to ([revision] changes
/// after a write) rather than holding a copy, so an entry saved in the form
/// shows up here without a separate refresh path.
class TransactionsPage extends StatefulWidget {
  /// Bumped by the shell after every write; see [didUpdateWidget].
  final int revision;

  /// True while a sync is in flight, for the app bar spinner.
  final bool syncing;

  /// Entries and members still waiting to reach the server.
  final int pendingTxns;
  final int pendingMembers;

  /// Explicit "sync now", which ignores the auto-sync cooldown.
  final Future<void> Function() onSync;

  final Future<void> Function() onDataChanged;
  final VoidCallback onOpenMembers;

  /// Test seam; the app leaves this null and gets [LocalDb.instance].
  final LocalDb? local;

  const TransactionsPage({
    super.key,
    required this.revision,
    required this.syncing,
    required this.pendingTxns,
    required this.pendingMembers,
    required this.onSync,
    required this.onDataChanged,
    required this.onOpenMembers,
    this.local,
  });

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  final _search = TextEditingController();

  LocalDb get _local => widget.local ?? LocalDb.instance;

  List<Txn> _all = [];
  bool _loading = true;

  /// 'all' | 'income' | 'expense', shown as the type filter chips.
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TransactionsPage old) {
    super.didUpdateWidget(old);
    if (widget.revision != old.revision) _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await _local.listTxns();
    if (!mounted) return;
    setState(() {
      _all = rows;
      _loading = false;
    });
  }

  /// Search across the fields a collector would actually type: the category, the
  /// member's name, a note, the receipt number.
  List<Txn> get _visible {
    final q = _search.text.trim().toLowerCase();
    return _all.where((t) {
      if (_filter != 'all' && t.type != _filter) return false;
      if (q.isEmpty) return true;
      return [t.category, t.donorName, t.description, t.receiptNumber]
          .any((v) => v != null && v.toLowerCase().contains(q));
    }).toList();
  }

  String get _pendingLabel {
    final t = widget.pendingTxns;
    final m = widget.pendingMembers;
    if (t == 0 && m == 0) return 'Everything is synced';
    final parts = [
      if (t > 0) '$t transaction(s)',
      if (m > 0) '$m member(s)',
    ];
    return '${parts.join(', ')} waiting to sync';
  }

  double get _income => _all
      .where((t) => t.type == 'income')
      .fold(0, (s, t) => s + t.amount);
  double get _expense => _all
      .where((t) => t.type == 'expense')
      .fold(0, (s, t) => s + t.amount);

  Future<void> _openForm({Txn? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AddTxnSheet(
        existing: existing,
        onSave: (t) async {
          await _local.insertTxn(t);
          // best-effort immediate push; stays local if offline
          await widget.onDataChanged();
        },
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _viewTxn(Txn t) async {
    await showDialog(
      context: context,
      builder: (_) => _TxnDetailSheet(txn: t, onEdit: () {
        Navigator.pop(context);
        _openForm(existing: t);
      }),
    );
  }

  Future<void> _deleteTxn(Txn t) async {
    final fmt = NumberFormat('#,##0.##');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete transaction?'),
        content: Text(
            '${t.category} • ${fmt.format(t.amount)}\n'
            'It is removed here and on the server at the next sync.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _local.softDelete(t.id);
    await _load();
    await widget.onDataChanged();
  }

  Future<void> _changePin() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change PIN'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'New PIN (min 4 digits)',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
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
                          size: 18, color: c.ok ? Colors.green : Colors.red),
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
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moshjid Transactions'),
        actions: [
          if (!AppConfig.isSupabaseConfigured)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(
                  label: Text('offline-only'),
                  visualDensity: VisualDensity.compact),
            ),
          if (widget.syncing)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else
            IconButton(
              tooltip: _pendingLabel,
              onPressed: widget.onSync,
              icon: Badge(
                isLabelVisible: widget.pendingTxns > 0,
                label: Text('${widget.pendingTxns}'),
                child: const Icon(Icons.sync),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'members') widget.onOpenMembers();
              if (v == 'pin') _changePin();
              if (v == 'health') _checkConnection();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'members', child: Text('Members')),
              PopupMenuItem(value: 'pin', child: Text('Change PIN')),
              PopupMenuItem(value: 'health', child: Text('Check connection')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _TotalsBar(income: _income, expense: _expense),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search category, member, receipt…',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final f in const ['all', 'income', 'expense']) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f == 'all'
                          ? 'All'
                          : TxnTypeStyle.of(f).label),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                    ? _EmptyState(
                        hasFilter: _search.text.isNotEmpty || _filter != 'all',
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          await _load();
                          await widget.onDataChanged();
                        },
                        child: ListView.separated(
                          itemCount: visible.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, indent: 72),
                          itemBuilder: (_, i) {
                            final t = visible[i];
                            return _TxnTile(
                              txn: t,
                              onTap: () => _viewTxn(t),
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
}

class _EmptyState extends StatelessWidget {
  final bool hasFilter;
  const _EmptyState({required this.hasFilter});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          hasFilter
              ? 'Nothing matches this filter.'
              : 'No transactions yet.\nTap + to record one.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      ),
    );
  }
}

class _TotalsBar extends StatelessWidget {
  final double income, expense;
  const _TotalsBar({required this.income, required this.expense});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final incomeStyle = TxnTypeStyle.of('income');
    final expenseStyle = TxnTypeStyle.of('expense');
    final fmt = NumberFormat('#,##0.##');
    final balance = income - expense;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.12),
              theme.colorScheme.primary.withValues(alpha: 0.04),
            ],
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(
          children: [
            _cell(context, 'Income', income, incomeStyle.color, fmt),
            _cell(context, 'Expense', expense, expenseStyle.color, fmt),
            _cell(context, 'Balance', balance, theme.colorScheme.onSurface, fmt),
          ],
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, String label, double v, Color c,
          NumberFormat fmt) =>
      Expanded(
        child: Column(
          children: [
            Text(label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.grey.shade700)),
            const SizedBox(height: 2),
            Text(fmt.format(v),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: c)),
          ],
        ),
      );
}

class _TxnTile extends StatelessWidget {
  final Txn txn;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TxnTile({
    required this.txn,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = TxnTypeStyle.of(txn.type);
    final fmt = NumberFormat('#,##0.##');
    final sign = txn.type == 'income' ? '+' : '-';

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: style.color.withValues(alpha: 0.12),
        child: Icon(style.icon, color: style.color, size: 20),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(txn.category,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Text(
            '$sign${fmt.format(txn.amount)}',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: style.color, fontSize: 15),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          children: [
            if (!txn.isSynced) ...[
              Icon(Icons.cloud_upload_outlined,
                  size: 14, color: theme.colorScheme.tertiary),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                [
                  DateFormat('d MMM').format(txn.date),
                  txn.paymentMethod.toUpperCase(),
                  if (txn.hasDonor) txn.donorName,
                ].whereType<String>().join(' • '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'edit') onEdit();
          if (v == 'delete') onDelete();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

/// Read-only detail, as its own sheet so long notes are not crammed into a
/// dialog.
class _TxnDetailSheet extends StatelessWidget {
  final Txn txn;
  final VoidCallback onEdit;

  const _TxnDetailSheet({required this.txn, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final style = TxnTypeStyle.of(txn.type);
    final fmt = NumberFormat('#,##0.##');

    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 110,
                  child: Text(k,
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 12))),
              Expanded(
                child: Text(v,
                    style: const TextStyle(fontSize: 13, height: 1.3)),
              ),
            ],
          ),
        );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(style.icon, color: style.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(txn.category,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context)),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    row('Type', style.label),
                    row('Amount', fmt.format(txn.amount)),
                    row('Category', txn.category),
                    if (txn.hasDonor) row('Member', txn.donorName ?? '(unnamed)'),
                    if (txn.donorPhone != null && txn.donorPhone!.isNotEmpty)
                      row('Member phone', txn.donorPhone!),
                    row('Method', txn.paymentMethod),
                    row('Date', DateFormat('yyyy-MM-dd').format(txn.date)),
                    row('Status', txn.status),
                    if (txn.description != null) row('Note', txn.description!),
                    if (txn.receiptNumber != null)
                      row('Receipt', txn.receiptNumber!),
                    row('Sync', txn.isSynced ? 'Synced' : 'Waiting to sync'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit),
                label: const Text('Edit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}