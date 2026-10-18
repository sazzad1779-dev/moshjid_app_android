import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/app_config.dart';
import '../data/local/local_db.dart';
import '../data/sync/sync_service.dart';
import 'widgets/type_selector.dart';

/// Dashboard: summary totals, date-range filter, category breakdown.
///
/// Reads the cloud transaction table on every [revision] change. Sync is
/// handled by the shell; the dashboard intentionally displays server records
/// only, not transactions that are still local and unsynced.
class DashboardPage extends StatefulWidget {
  final int revision;
  final bool syncing;
  final int pendingTxns;
  final int pendingMembers;
  final Future<void> Function() onSync;
  final Future<void> Function() onDataChanged;
  final LocalDb? local;

  const DashboardPage({
    super.key,
    required this.revision,
    required this.syncing,
    required this.pendingTxns,
    required this.pendingMembers,
    required this.onSync,
    required this.onDataChanged,
    this.local,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final SyncService _sync;
  List<Map<String, dynamic>> _cloudTxns = [];
  bool _loading = true;
  String? _loadError;

  DateTimeRange? _dateRange;
  String _filter = 'all';
  String _categoryFilter = 'all';

  @override
  void initState() {
    super.initState();
    _sync = SyncService(widget.local ?? LocalDb.instance);
    _load();
  }

  @override
  void didUpdateWidget(DashboardPage old) {
    super.didUpdateWidget(old);
    if (widget.revision != old.revision) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final rows = await _sync.pullTransactions(
        startDate: _dateRange?.start,
        endDate: _dateRange?.end,
      );
      if (!mounted) return;
      setState(() {
        _cloudTxns = rows ?? [];
        _loading = false;
        _loadError = rows == null
            ? 'Cloud data is unavailable. Check your connection and Supabase configuration.'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cloudTxns = [];
        _loading = false;
        _loadError = 'Failed to load transactions from cloud: $e';
      });
    }
  }

  String _typeOf(Map<String, dynamic> txn) =>
      (txn['transaction_categories'] as Map<String, dynamic>?)?['type']
          as String? ??
      'other';

  String _categoryOf(Map<String, dynamic> txn) =>
      (txn['transaction_categories'] as Map<String, dynamic>?)?['name']
          as String? ??
      'Unknown';

  List<String> get _categories =>
      _cloudTxns.map(_categoryOf).toSet().toList()..sort();

  List<Map<String, dynamic>> get _visible {
    return _cloudTxns.where((t) {
      if (_filter != 'all' && _typeOf(t) != _filter) return false;
      if (_categoryFilter != 'all' && _categoryOf(t) != _categoryFilter) {
        return false;
      }
      return true;
    }).toList();
  }

  Map<String, double> _categoryTotalsFor(String type) {
    final map = <String, double>{};
    for (final t in _visible) {
      if (_typeOf(t) != type) continue;
      final category = _categoryOf(t);
      final amount = (t['amount'] as num?)?.toDouble() ?? 0;
      map[category] = (map[category] ?? 0) + amount;
    }
    return map;
  }

  Map<String, double> get _categoryIncome => _categoryTotalsFor('income');
  Map<String, double> get _categoryExpense => _categoryTotalsFor('expense');
  Map<String, double> get _categoryOther => _categoryTotalsFor('other');

  double get _totalIncome => _visible
      .where((t) => _typeOf(t) == 'income')
      .fold(0, (s, t) => s + ((t['amount'] as num?)?.toDouble() ?? 0));

  double get _totalExpense => _visible
      .where((t) => _typeOf(t) == 'expense')
      .fold(0, (s, t) => s + ((t['amount'] as num?)?.toDouble() ?? 0));

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: _dateRange,
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme
              .copyWith(primary: Theme.of(context).colorScheme.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _dateRange = picked);
      await _load();
    }
  }

  Future<void> _clearDateRange() async {
    setState(() => _dateRange = null);
    await _load();
  }

  String get _dateRangeLabel {
    if (_dateRange == null) return 'All time';
    final f = DateFormat('d MMM yyyy');
    return '${f.format(_dateRange!.start)} – ${f.format(_dateRange!.end)}';
  }

  String get _pendingLabel {
    final t = widget.pendingTxns;
    final m = widget.pendingMembers;
    if (t == 0 && m == 0) return 'Everything is synced';
    final parts = [if (t > 0) '$t transaction(s)', if (m > 0) '$m member(s)'];
    return '${parts.join(', ')} waiting to sync';
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.##');
    final visible = _visible;
    final isOffline = !AppConfig.isSupabaseConfigured;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          if (!AppConfig.isSupabaseConfigured)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Chip(
                label: Text('offline-only'),
                visualDensity: VisualDensity.compact,
              ),
            ),
          if (widget.syncing)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
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
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
                    const SizedBox(height: 12),
                    Text(
                      _loadError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                await _load();
                await widget.onDataChanged();
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _DateRangeRow(
                    label: _dateRangeLabel,
                    onTap: isOffline ? null : _pickDateRange,
                    onClear: _dateRange != null ? _clearDateRange : null,
                  ),
                  if (isOffline)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Cloud data unavailable in offline mode',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: 16),
                  _TotalsBar(income: _totalIncome, expense: _totalExpense),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final f in const [
                          'all',
                          'income',
                          'expense',
                          'other',
                        ]) ...[
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(
                                f == 'all' ? 'All' : TxnTypeStyle.of(f).label,
                              ),
                              selected: _filter == f,
                              onSelected: (_) => setState(() => _filter = f),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _categories.contains(_categoryFilter)
                            ? _categoryFilter
                            : 'all',
                        items: [
                          const DropdownMenuItem(
                            value: 'all',
                            child: Text('All categories'),
                          ),
                          for (final category in _categories)
                            DropdownMenuItem(
                              value: category,
                              child: Text(category),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _categoryFilter = value ?? 'all'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (visible.isEmpty)
                    _EmptyState(
                      hasFilter:
                          _dateRange != null ||
                          _filter != 'all' ||
                          _categoryFilter != 'all',
                      isOffline: isOffline,
                    )
                  else ...[
                    if (_categoryIncome.isNotEmpty) ...[
                      _CategorySection(
                        title: 'Income by Category',
                        categories: _categoryIncome,
                        color: TxnTypeStyle.of('income').color,
                        fmt: fmt,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_categoryExpense.isNotEmpty) ...[
                      _CategorySection(
                        title: 'Expense by Category',
                        categories: _categoryExpense,
                        color: TxnTypeStyle.of('expense').color,
                        fmt: fmt,
                      ),
                    ],
                    if (_categoryOther.isNotEmpty) ...[
                      _CategorySection(
                        title: 'Other by Category',
                        categories: _categoryOther,
                        color: TxnTypeStyle.of('other').color,
                        fmt: fmt,
                      ),
                    ],
                    const SizedBox(height: 16),
                    _TransactionsSection(transactions: visible),
                  ],
                ],
              ),
            ),
    );
  }
}

class _DateRangeRow extends StatelessWidget {
  final String label;
  final Future<void> Function()? onTap;
  final Future<void> Function()? onClear;

  const _DateRangeRow({required this.label, this.onTap, this.onClear});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap != null ? () => onTap!() : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.date_range, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onClear != null)
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => onClear!(),
                tooltip: 'Clear date range',
              ),
          ],
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

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.12),
            theme.colorScheme.primary.withValues(alpha: 0.04),
          ],
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Row(
        children: [
          _cell(context, 'Income', income, incomeStyle.color, fmt),
          _cell(context, 'Expense', expense, expenseStyle.color, fmt),
          _cell(context, 'Balance', balance, theme.colorScheme.onSurface, fmt),
        ],
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    String label,
    double v,
    Color c,
    NumberFormat fmt,
  ) => Expanded(
    child: Column(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: Colors.grey.shade700),
        ),
        const SizedBox(height: 2),
        Text(
          fmt.format(v),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c),
        ),
      ],
    ),
  );
}

class _CategorySection extends StatelessWidget {
  final String title;
  final Map<String, double> categories;
  final Color color;
  final NumberFormat fmt;

  const _CategorySection({
    required this.title,
    required this.categories,
    required this.color,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = categories.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: color.withValues(alpha: 0.12),
                    child: Icon(
                      Icons.category_outlined,
                      color: color,
                      size: 16,
                    ),
                  ),
                  title: Text(
                    entries[i].key,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  trailing: Text(
                    fmt.format(entries[i].value),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _TransactionsSection extends StatelessWidget {
  final List<Map<String, dynamic>> transactions;

  const _TransactionsSection({required this.transactions});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.##');
    final dateFmt = DateFormat('d MMM yyyy');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Transactions (${transactions.length})',
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < transactions.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                Builder(
                  builder: (context) {
                    final txn = transactions[i];
                    final type =
                        (txn['transaction_categories']
                                as Map<String, dynamic>?)?['type']
                            as String? ??
                        'other';
                    final category =
                        (txn['transaction_categories']
                                as Map<String, dynamic>?)?['name']
                            as String? ??
                        'Unknown';
                    final date = DateTime.tryParse('${txn['date'] ?? ''}');
                    final amount = (txn['amount'] as num?)?.toDouble() ?? 0;
                    final color = TxnTypeStyle.of(type).color;
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: color.withValues(alpha: 0.12),
                        child: Icon(
                          TxnTypeStyle.of(type).icon,
                          color: color,
                          size: 16,
                        ),
                      ),
                      title: Text(category),
                      subtitle: Text(
                        '${TxnTypeStyle.of(type).label}'
                        '${date == null ? '' : ' • ${dateFmt.format(date)}'}'
                        '${txn['receipt_number'] == null ? '' : ' • ${txn['receipt_number']}'}',
                      ),
                      trailing: Text(
                        fmt.format(amount),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasFilter;
  final bool isOffline;
  const _EmptyState({required this.hasFilter, this.isOffline = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          isOffline
              ? 'Cloud data unavailable in offline mode.\nConfigure Supabase to view dashboard.'
              : hasFilter
              ? 'No transactions match these filters.'
              : 'No cloud transactions found.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      ),
    );
  }
}
