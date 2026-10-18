import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

const _pinKey = 'moshjid_pin';

Future<String> storedPin() async {
  final p = await SharedPreferences.getInstance();
  return p.getString(_pinKey) ?? AppConfig.defaultPin;
}

Future<void> savePin(String pin) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(_pinKey, pin);
}

/// Simple shared-PIN gate for v1. PIN stored locally (obscured, not encrypted
/// — acceptable for v1 single-device mosque use; move to Supabase Auth later).
class PinGate extends StatefulWidget {
  final void Function() onUnlocked;
  const PinGate({super.key, required this.onUnlocked});

  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final expected = await storedPin();
    if (_ctrl.text.trim() == expected) {
      widget.onUnlocked();
    } else {
      setState(() {
        _error = 'Wrong PIN';
        _busy = false;
      });
      return;
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Moshjid Transactions')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.mosque, size: 56),
            const SizedBox(height: 12),
            const Text('Enter mosque PIN to continue'),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'PIN',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onSubmitted: (_) => _unlock(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _unlock,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Unlock'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Default PIN is 1234 — change it from the menu after login.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
