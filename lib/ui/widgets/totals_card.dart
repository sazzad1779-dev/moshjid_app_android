import 'package:flutter/material.dart';

import '../../data/models/txn_summary.dart';
import '../format.dart';

/// Income / expense / balance figures. Values come from a SQL aggregate,
/// never from summing a partial page of the list.
class TotalsCard extends StatelessWidget {
  final TxnSummary summary;
  final String? caption;

  const TotalsCard({super.key, required this.summary, this.caption});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            Row(
              children: [
                _cell('Income', summary.income, Colors.green),
                _cell('Expense', summary.expense, Colors.red),
                _cell(
                  'Balance',
                  summary.balance,
                  summary.balance < 0 ? Colors.red : Colors.black87,
                ),
              ],
            ),
            if (caption != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  caption!,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Widget _cell(String label, double v, Color c) => Expanded(
    child: Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 2),
        FittedBox(
          child: Text(
            Fmt.money(v),
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: c,
            ),
          ),
        ),
      ],
    ),
  );
}
