/// Aggregated income/expense figures for a date range. Computed in SQL so
/// the dashboard is never derived from a truncated page of transactions.
class TxnSummary {
  final double income;
  final double expense;
  final int count;

  const TxnSummary({this.income = 0, this.expense = 0, this.count = 0});

  static const empty = TxnSummary();

  double get balance => income - expense;

  TxnSummary operator +(TxnSummary o) => TxnSummary(
    income: income + o.income,
    expense: expense + o.expense,
    count: count + o.count,
  );
}
