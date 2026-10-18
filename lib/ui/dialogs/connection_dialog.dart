import 'package:flutter/material.dart';

import '../../data/auth/health_check.dart';

/// Runs the Supabase connectivity checks and renders the per-check result.
Future<void> showConnectionDialog(BuildContext context) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      title: Text('Checking connection...'),
      content: SizedBox(
        height: 48,
        child: Center(child: CircularProgressIndicator()),
      ),
    ),
  );

  final health = await checkSupabaseHealth();
  if (!context.mounted) return;
  Navigator.pop(context); // close the progress dialog

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(health.ok ? 'All systems OK' : 'Connection issues'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              health.summary(),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final c in health.checks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      c.ok ? Icons.check_circle : Icons.error,
                      size: 18,
                      color: c.ok ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${c.name}\n${c.detail}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
