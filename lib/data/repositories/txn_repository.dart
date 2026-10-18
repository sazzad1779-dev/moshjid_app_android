import '../local/local_db.dart';
import '../models/txn.dart';
import '../models/txn_summary.dart';
import '../sync/sync_service.dart';

/// One page of transactions plus the total matching count.
class TxnPage {
  final List<Txn> items;
  final int total;
  const TxnPage({required this.items, required this.total});

  bool get hasMore => items.length < total;
}

/// Filter applied to the transaction list and the summary figures.
class TxnFilter {
  /// 'all' | 'income' | 'expense' | 'other'
  final String type;
  final DateTime? from;
  final DateTime? to;
  final String search;

  const TxnFilter({this.type = 'all', this.from, this.to, this.search = ''});

  const TxnFilter.all() : this();

  bool get isAll => type == 'all';

  TxnFilter copyWith({
    String? type,
    DateTime? from,
    DateTime? to,
    String? search,
    bool clearRange = false,
  }) => TxnFilter(
    type: type ?? this.type,
    from: clearRange ? null : (from ?? this.from),
    to: clearRange ? null : (to ?? this.to),
    search: search ?? this.search,
  );

  /// True when the filter selects everything — lets the summary use a
  /// cheaper query and the UI hide the filter controls.
  bool get isEmpty =>
      isAll && from == null && to == null && search.trim().isEmpty;
}

/// Single entry point for transaction data.
///
/// Owns the one [LocalDb] and [SyncService] for the app so no widget has to
/// construct its own (which used to open duplicate database handles), and
/// centralises "write locally, then try to sync".
class TxnRepository {
  final LocalDb _local;
  final SyncService _sync;

  TxnRepository._(this._local, this._sync);

  factory TxnRepository({LocalDb? local, SyncService? sync}) {
    final db = local ?? LocalDb();
    return TxnRepository._(db, sync ?? SyncService(db));
  }

  LocalDb get local => _local;
  SyncService get sync => _sync;

  Future<TxnPage> load({
    TxnFilter filter = const TxnFilter.all(),
    int limit = 50,
    int offset = 0,
  }) async {
    final items = await _local.listTxns(
      limit: limit,
      offset: offset,
      type: filter.type,
      from: filter.from,
      to: filter.to,
      search: filter.search,
    );
    final total = await _local.totalTxns(
      type: filter.type,
      from: filter.from,
      to: filter.to,
      search: filter.search,
    );
    return TxnPage(items: items, total: total);
  }

  Future<TxnSummary> summary({TxnFilter filter = const TxnFilter.all()}) =>
      _local.summarize(from: filter.from, to: filter.to);

  Future<int> pendingCount() => _local.pendingCount();

  /// Saves to the local store first — the only write path that must never
  /// fail because of the network.
  Future<void> save(Txn t) => _local.insertTxn(t);

  /// Bulk insert (used by tooling and tests). Returns the row count.
  Future<int> saveMany(List<Txn> ts) => _local.insertTxns(ts);

  Future<void> delete(String id) => _local.softDelete(id);

  Future<SyncResult> syncNow() => _sync.pushPending();

  Future<void> refreshCategories() => _sync.refreshCategories();

  Future<List<String>> categoryNames(String type) async {
    final cached = await _local.cachedCategories(type);
    if (cached.isNotEmpty) {
      final names = cached.map((e) => e['name'] as String).toList()..sort();
      return names;
    }
    return AppCategories.namesFor(type);
  }
}

/// Offline fallback category list, mirroring the categories already in
/// `transaction_categories`. Replaced by the server cache when online.
class AppCategories {
  static const String income = 'income';
  static const String expense = 'expense';
  static const String other = 'other';

  /// Exact names as stored in the database and used in the paper ledger,
  /// e.g. `Electricity Bill (বিদ্যুৎ বিল)`.
  static const _names = <String, List<String>>{
    income: [
      'Regular Donation (নিয়মিত দান)',
      'Regular Donation (বাহিরের দানবাক্স)',
      'Friday Collection (জুমার দান)',
      'Imam Salary (ইমামের বেতন)',
      'Electricity Bill (বিদ্যুৎ বিল)',
      'Maintenance (রক্ষণাবেক্ষণ)',
      'Other Income',
    ],
    expense: [
      'Maintenance (রক্ষণাবেক্ষণ)',
      'Electricity Bill (বিদ্যুৎ বিল)',
      'Imam Salary (ইমামের বেতন)',
      'Other Expense',
    ],
    other: ['Other Income', 'Other Expense'],
  };

  static List<String> namesFor(String type) =>
      List<String>.unmodifiable(_names[type] ?? _names[other]!);

  static bool exists(String type, String name) => namesFor(type).contains(name);

  /// Strips the `English (বাংলা)` suffix for compact list rows.
  static String shortLabel(String name) {
    final i = name.indexOf(RegExp(r'\s*\('));
    if (i > 0 && name.endsWith(')')) return name.substring(0, i);
    return name;
  }
}
