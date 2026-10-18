import 'package:flutter/material.dart';

import '../../data/models/txn.dart';
import '../format.dart';
import 'txn_entry_sheet.dart';

/// Read-only detail view of a transaction.
Future<void> showTxnDetail(BuildContext context, Txn t) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${t.category}\n${Fmt.money(t.amount)}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row('Type', t.type),
            _row('Category', t.category),
            _row('Amount', Fmt.money(t.amount)),
            _row('Method', t.paymentMethod),
            _row('Date', Fmt.date(t.date)),
            _row('Status', t.status),
            if (t.description != null) _row('Note', t.description!),
            if (t.receiptNumber != null) _row('Receipt', t.receiptNumber!),
            _row('Sync', t.isSynced ? 'synced' : 'pending'),
            _row('Entered by', t.enteredBy),
            _row('Saved at', t.clientCreatedAt.toIso8601String()),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            showTxnEntrySheet(context, existing: t);
          },
          child: const Text('Edit'),
        ),
      ],
    ),
  );
}

Widget _row(String k, String v) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 96,
        child: Text(
          k,
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
      ),
      Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
    ],
  ),
);
