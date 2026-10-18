import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/app_config.dart';
import '../data/local/local_db.dart';
import '../data/models/profile.dart';
import '../data/models/txn.dart';
import 'widgets/member_editor.dart' show showNewMemberDialog;
import 'widgets/member_picker.dart';
import 'widgets/txn_form_sheet.dart';
import 'widgets/type_selector.dart';

/// The member roster, straight out of the local database.
///
/// Everything here works offline: the list is `profiles_cache`, which the Excel
/// import, other devices and this device's own collection all write to. A
/// member added here is a real row from the moment it is saved, and sync
/// pushes it to the cloud before any transaction that references it.
class MembersPage extends StatefulWidget {
  /// Bumped by the shell after every write; see [didUpdateWidget].
  final int revision;
  final Future<void> Function() onDataChanged;

  /// Test seam; the app leaves this null and gets [LocalDb.instance].
  final LocalDb? local;

  const MembersPage({
    super.key,
    required this.revision,
    required this.onDataChanged,
    this.local,
  });

  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  final _search = TextEditingController();

  LocalDb get _local => widget.local ?? LocalDb.instance;

  List<Profile> _all = [];
  Map<String, double> _totals = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MembersPage old) {
    super.didUpdateWidget(old);
    if (widget.revision != old.revision) _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // The roster is the whole tab, so read it unfiltered and filter in memory
    // against the same normalised keys the database uses, rather than issuing a
    // new query per keystroke.
    final members = await _local.allProfiles();
    final totals = <String, double>{};
    for (final m in members) {
      totals[m.id] = await _local.memberTotal(m.id);
    }
    if (!mounted) return;
    setState(() {
      _all = members;
      _totals = totals;
      _loading = false;
    });
  }

  List<Profile> get _visible {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all
        .where((p) =>
            p.displayName.toLowerCase().contains(q) ||
            (p.phone ?? '').toLowerCase().contains(q))
        .toList();
  }

  Future<void> _addMember() async {
    final created = await showNewMemberDialog(context, local: _local);
    if (created == null || !mounted) return;
    await _load();
    await widget.onDataChanged();
  }

  Future<void> _openMember(Profile p) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MemberDetailSheet(
        member: p,
        local: _local,
        onDataChanged: () async {
          await _load();
          await widget.onDataChanged();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final pending = _all.where((p) => p.isPending).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Members'),
        actions: [
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '$pending to sync',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search members',
                prefixIcon: const Icon(Icons.search),
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
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _all.isEmpty
                                ? 'No members yet.\nTap + to add the first one.'
                                : 'No member matches "${_search.text.trim()}".',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          await _load();
                          await widget.onDataChanged();
                        },
                        child: ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (_, i) {
                            final p = visible[i];
                            return MemberTile(
                              profile: p,
                              trailingText: (_totals[p.id] ?? 0) > 0
                                  ? NumberFormat('#,##0.##')
                                      .format(_totals[p.id])
                                  : null,
                              onTap: () => _openMember(p),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addMember,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add member'),
      ),
    );
  }
}

/// One member: their details, their payment history, and a shortcut for
/// recording the next Imam Hadiya payment without going through the picker.
class _MemberDetailSheet extends StatefulWidget {
  final Profile member;
  final LocalDb local;
  final Future<void> Function() onDataChanged;

  const _MemberDetailSheet({
    required this.member,
    required this.local,
    required this.onDataChanged,
  });

  @override
  State<_MemberDetailSheet> createState() => _MemberDetailSheetState();
}

class _MemberDetailSheetState extends State<_MemberDetailSheet> {
  List<Txn> _txns = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.local.txnsForMember(widget.member.id);
    if (!mounted) return;
    setState(() {
      _txns = rows;
      _loading = false;
    });
  }

  /// Records income for this member: the form opens with the type and category
  /// that carry a member, and the member already chosen, so the only thing left
  /// to enter is the amount.
  Future<void> _recordPayment() async {
    final category = _donorCategoryFor('income');
    if (category == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No member category is configured for income')));
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AddTxnSheet(
        local: widget.local,
        initialType: 'income',
        initialCategory: category,
        initialMember: widget.member,
        onSave: (t) async {
          await widget.local.insertTxn(t);
          await _load();
          await widget.onDataChanged();
        },
      ),
    );
  }

  /// The category whose income rows belong to a member. Derived from the config
  /// rather than hardcoded, so a rename on the server does not need a second
  /// edit here.
  static String? _donorCategoryFor(String type) {
    for (final entry in AppConfig.donorCategories) {
      final parts = entry.split('|');
      if (parts.length == 2 && parts[1] == type) return parts[0];
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = widget.member;
    final fmt = NumberFormat('#,##0.##');
    final collected = _txns
        .where((t) => t.type == 'income')
        .fold<double>(0, (s, t) => s + t.amount);
    final spent = _txns
        .where((t) => t.type != 'income')
        .fold<double>(0, (s, t) => s + t.amount);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: m.isPending
                      ? theme.colorScheme.tertiaryContainer
                      : theme.colorScheme.primaryContainer,
                  child: Text(initialsOf(m.displayName),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m.displayName,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      Text(
                        [
                          if (m.phone != null) m.phone!,
                          if (m.isMonthly) 'Monthly',
                          m.isPending ? 'Waiting to sync' : 'On the server',
                        ].join(' • '),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context)),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  _stat('Collected', fmt.format(collected),
                      TxnTypeStyle.of('income').color),
                  _stat('Paid out', fmt.format(spent),
                      TxnTypeStyle.of('expense').color),
                  _stat('Entries', '${_txns.length}', theme.colorScheme.onSurface),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _recordPayment,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Record a payment'),
              ),
            ),
            const SizedBox(height: 12),
            Text('History',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Flexible(
              child: _loading
                  ? const Center(
                      child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator()))
                  : _txns.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text('No transactions for this member yet.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey)),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: _txns.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final t = _txns[i];
                            final style = TxnTypeStyle.of(t.type);
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(style.icon, color: style.color, size: 18),
                              title: Text(t.category,
                                  style: const TextStyle(fontSize: 14)),
                              subtitle: Text(
                                '${DateFormat('yyyy-MM-dd').format(t.date)} • '
                                '${t.paymentMethod.toUpperCase()}'
                                '${t.isSynced ? '' : ' • waiting to sync'}',
                                style: theme.textTheme.bodySmall,
                              ),
                              trailing: Text(
                                '${t.type == 'income' ? '+' : '-'}${fmt.format(t.amount)}',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: style.color),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, Color color) => Expanded(
        child: Column(
          children: [
            Text(label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15, color: color)),
          ],
        ),
      );
}