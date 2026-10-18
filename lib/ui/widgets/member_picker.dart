import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/local/local_db.dart';
import '../../data/models/profile.dart';
import 'member_editor.dart' show showNewMemberDialog;

/// Full-screen roster picker.
///
/// The inline suggestion box in the transaction form only ever showed a handful
/// of rows; this is the whole list from the local database, so a collector can
/// browse members as well as search them. It works entirely offline and reads
/// straight from `profiles_cache`, which is also what the server roster is
/// pulled into.
Future<Profile?> showMemberPicker(
  BuildContext context, {
  required LocalDb local,
  Profile? initial,
}) {
  return Navigator.of(context).push<Profile>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _MemberPickerPage(local: local, initial: initial),
    ),
  );
}

class _MemberPickerPage extends StatefulWidget {
  final LocalDb local;
  final Profile? initial;

  const _MemberPickerPage({required this.local, this.initial});

  @override
  State<_MemberPickerPage> createState() => _MemberPickerPageState();
}

class _MemberPickerPageState extends State<_MemberPickerPage> {
  static const _debounceDelay = Duration(milliseconds: 150);

  final _search = TextEditingController();
  Timer? _debounce;

  List<Profile> _results = [];
  String? _selectedId;
  bool _loading = true;

  /// A slow search landing after a newer one would replace the list the user is
  /// reading right now.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initial?.id;
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(String query) async {
    final generation = ++_generation;
    setState(() => _loading = true);
    try {
      // An empty box lists the roster itself; the picker's own "recent first"
      // ordering would hide most of the members from a browsing collector.
      final found = query.trim().isEmpty
          ? await widget.local.allProfiles()
          : await widget.local.searchProfiles(query, limit: 40);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = found;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = const [];
        _loading = false;
      });
    }
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => _load(query));
  }

  /// Creates the member locally straight away, so the row is in the database
  /// before the transaction that references it is saved. Sync pushes the member
  /// and the transaction in that order.
  Future<void> _addMember() async {
    final created = await showNewMemberDialog(context, local: widget.local);
    if (created == null || !mounted) return;
    await _load(_search.text);
    if (!mounted) return;
    Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim();
    // Offer creation only when the typed name is not already in the list, so a
    // near-miss cannot create a second row for one person by accident.
    final canAdd = query.length >= 2 &&
        !_results.any((p) => p.fullName.toLowerCase() == query.toLowerCase());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Members'),
        actions: [
          IconButton(
            tooltip: 'New member',
            onPressed: _addMember,
            icon: const Icon(Icons.person_add_alt),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _search,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onChanged: _onQueryChanged,
              decoration: InputDecoration(
                hintText: 'Search members',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _search.clear();
                          _load('');
                          setState(() {});
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (canAdd)
            ListTile(
              dense: true,
              leading: Icon(Icons.person_add_alt, color: Theme.of(context).colorScheme.primary),
              title: Text('Add "$query" as a new member'),
              onTap: _addMember,
            ),
          Expanded(
            child: _loading && _results.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            query.isEmpty
                                ? 'No members yet.\nTap + to add the first one.'
                                : 'No member matches "$query".\nTap the row above to add them.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (_, i) {
                          final p = _results[i];
                          return MemberTile(
                            profile: p,
                            selected: p.id == _selectedId,
                            onTap: () => Navigator.of(context).pop(p),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

/// One row of the roster, reused by the picker and the members tab.
class MemberTile extends StatelessWidget {
  final Profile profile;

  /// Optional right-hand summary, e.g. "collected 1,200".
  final String? trailingText;

  /// Ring around the leading avatar when this is the current selection.
  final bool selected;

  final VoidCallback? onTap;

  const MemberTile({
    super.key,
    required this.profile,
    this.trailingText,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = profile.isPending;

    return ListTile(
      onTap: onTap,
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.06),
      leading: CircleAvatar(
        backgroundColor:
            pending ? theme.colorScheme.tertiaryContainer : theme.colorScheme.primaryContainer,
        child: Text(
          initialsOf(profile.displayName),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: pending
                ? theme.colorScheme.onTertiaryContainer
                : theme.colorScheme.onPrimaryContainer,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              profile.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (pending) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Saved on this device, syncs when online',
              child: Icon(Icons.cloud_upload_outlined,
                  size: 14, color: theme.colorScheme.tertiary),
            ),
          ],
        ],
      ),
      subtitle: profile.phone == null
          ? const Text('No phone')
          : Text(profile.phone!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailingText == null
          ? null
          : Text(
              trailingText!,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }

}

/// Up to two letters for the avatar: the first letter of each of the first two
/// words. `characters` from the `characters` package would be the Unicode-aware
/// way to do this, but the app does not depend on it directly, and a naive
/// substring could split a Bengali grapheme cluster.
String initialsOf(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final w = parts.first;
    return w.substring(0, w.length < 2 ? w.length : 2).toUpperCase();
  }
  return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
}