import 'package:intl/intl.dart';

/// Shared display formatting so amounts and dates look the same everywhere.
class Fmt {
  Fmt._();

  static final _money = NumberFormat('#,##0.##');
  static final _date = DateFormat('yyyy-MM-dd');
  static final _dateBn = DateFormat('d MMM yyyy');

  /// 12345.5 -> "12,345.5" (no trailing ".00" noise).
  static String money(double v) => _money.format(v);

  static String date(DateTime d) => _date.format(d);
  static String dateLong(DateTime d) => _dateBn.format(d);
}
