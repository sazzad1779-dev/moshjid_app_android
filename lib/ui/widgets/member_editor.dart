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

class _NewMemberDialog extends StatefulWidget {
  final LocalDb? local;
  const _NewMemberDialog({this.local});

  @override
  State<_NewMemberDialog> createState() => _NewMemberDialogState();
}

class _NewMemberDialogState extends State<_NewMemberDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _saving = false;

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
    setState(() => _saving = true);

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
      title: const Text('New member'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          child: Text(_saving ? 'Saving…' : 'Add member'),
        ),
      ],
    );
  }
}