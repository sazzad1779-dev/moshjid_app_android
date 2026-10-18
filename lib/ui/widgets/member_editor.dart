import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/local/local_db.dart';
import '../../data/models/profile.dart';

/// Dialog for collecting a member who is not in the local cache yet.
///
/// Name is required and phone is optional, both validated here so a mistake is
/// visible while the person is still looking at the box. The row is written to
/// `profiles_cache` straight away as an unsynced local row, and sync pushes it
/// to the cloud before any transaction that references it -- which is what makes
/// collecting Imam Hadiya work with no network at all.
///
/// The same member typed twice never produces two rows: [LocalDb.ensureProfile]
/// matches on identity, not on text, so "Roxi" and "+880 1712 345678" resolve
/// to one person.
Future<Profile?> showNewMemberDialog(BuildContext context, {LocalDb? local}) {
  return showDialog<Profile>(
    context: context,
    builder: (ctx) => _NewMemberDialog(local: local),
  );
}

/// Dialog for changing a member who already exists.
///
/// Separate from [showNewMemberDialog] because the rules differ: an edit has an
/// identity to preserve and can be refused for colliding with somebody else,
/// where a create silently merges. Returns the updated member, or null if the
/// user backed out.
Future<Profile?> showEditMemberDialog(
  BuildContext context, {
  required Profile member,
  LocalDb? local,
}) {
  return showDialog<Profile>(
    context: context,
    builder: (ctx) => _NewMemberDialog(local: local, existing: member),
  );
}

class _NewMemberDialog extends StatefulWidget {
  final LocalDb? local;

  /// When set the dialog edits this member instead of creating one.
  final Profile? existing;

  const _NewMemberDialog({this.local, this.existing});

  @override
  State<_NewMemberDialog> createState() => _NewMemberDialogState();
}

class _NewMemberDialogState extends State<_NewMemberDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.fullName ?? '');
    _phone = TextEditingController(text: e?.phone ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  /// The member may already exist under this identity -- typed once with a
  /// number, once without. Say so instead of creating a second row.
  Future<Profile?> _existingMatch() async {
    final local = widget.local;
    if (local == null) return null;
    final probe =
        Profile.create(id: 'probe', fullName: _name.text, phone: _phone.text);
    return local.findProfileByMatchKey(probe.matchKey);
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    if (_isEdit) {
      final local = widget.local;
      if (local == null) {
        if (!mounted) return;
        Navigator.pop(
          context,
          widget.existing!.applyEdit(
            fullName: _name.text,
            phone: _phone.text,
            clearPhone: _phone.text.trim().isEmpty,
          ),
        );
        return;
      }
      final problem = await local.updateProfile(
        id: widget.existing!.id,
        fullName: _name.text,
        phone: _phone.text,
        clearPhone: _phone.text.trim().isEmpty,
      );
      if (!mounted) return;
      if (problem != null) {
        setState(() {
          _saving = false;
          _error = problem;
        });
        return;
      }
      final updated = await local.findProfileById(widget.existing!.id);
      if (!mounted) return;
      Navigator.pop(context, updated);
      return;
    }

    final existing = await _existingMatch();
    if (existing != null) {
      if (mounted) {
        setState(() => _saving = false);
        Navigator.pop(context, existing);
      }
      return;
    }

    // Written to the cache immediately and marked unsynced; SyncService pushes
    // it before any transaction that references it.
    if (widget.local != null) {
      final created = await widget.local!.ensureProfile(
        fullName: _name.text,
        phone: _phone.text,
      );
      if (mounted) Navigator.pop(context, created);
      return;
    }
    if (mounted) {
      Navigator.pop(
        context,
        Profile.create(
          id: 'pending',
          fullName: _name.text,
          phone: _phone.text,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit member' : 'New member'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              validator: Profile.validateName,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Phone (optional)',
                helperText: 'A phone identifies the member even if names differ',
                border: OutlineInputBorder(),
              ),
              validator: Profile.validatePhone,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving
                ? 'Saving…'
                : (_isEdit ? 'Save changes' : 'Add member')),
        ),
      ],
    );
  }
}