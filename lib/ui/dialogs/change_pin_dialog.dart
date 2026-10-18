import 'package:flutter/material.dart';

import '../pin_gate.dart';

/// Change the local device PIN that guards the app.
Future<void> showChangePinDialog(BuildContext context) async {
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
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  final pin = ctrl.text.trim();
  ctrl.dispose();
  if (ok == true && pin.length >= 4) {
    await savePin(pin);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PIN updated')));
    }
  }
}
