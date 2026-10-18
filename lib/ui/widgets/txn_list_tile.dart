import 'package:flutter/material.dart';

import '../../data/models/txn.dart';
import '../format.dart';

/// One row in the transaction list: category, amount, date and sync state.
class TxnListTile extends StatelessWidget {
  final Txn txn;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const TxnListTile({
    super.key,
    required this.txn,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = txn;
    final isIncome = t.type == 'income';
    final accent = isIncome ? Colors.green : Colors.red;
    final subtitle = [
      Fmt.date(t.date),
      t.paymentMethod,
      if (t.description != null) t.description!,
    ].join(' • ');

    return ListTile(
      onTap: onView,
      leading: CircleAvatar(
        backgroundColor: accent.withValues(alpha: 0.12),
        child: Icon(
          isIncome ? Icons.south_west : Icons.north_east,
          color: accent,
          size: 20,
        ),
      ),
      title: Text(
        '${t.category} • ${Fmt.money(t.amount)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            t.isSynced
                ? Icons.cloud_done_outlined
                : Icons.cloud_upload_outlined,
            size: 18,
            color: t.isSynced ? Colors.green : Colors.orange,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'view') onView();
              if (v == 'edit') onEdit();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'view', child: Text('View')),
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}
