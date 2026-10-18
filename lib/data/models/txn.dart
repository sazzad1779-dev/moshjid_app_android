import 'package:uuid/uuid.dart';

/// Local-first transaction model. Mirrors the Supabase `transactions`
/// table subset used in v1.
class Txn {
  final String id;
  final String type; // income | expense | other
  final String category; // display name (resolved to category_id on sync)
  final String? categoryId;
  final double amount;
  final String paymentMethod;
  final String status;
  final String? description;
  final String? receiptNumber;
  final DateTime date; // date-only (yyyy-MM-dd)
  final String enteredBy;
  final DateTime clientCreatedAt;
  final DateTime? syncedAt;
  final bool isDeleted;

  /// True while the row has never reached the server. Only then may the
  /// sync write `created_at`; afterwards the column is left alone so an
  /// edit never rewrites the original creation time.
  final bool isNew;

  Txn({
    required this.id,
    required this.type,
    required this.category,
    this.categoryId,
    required this.amount,
    required this.paymentMethod,
    required this.status,
    this.description,
    this.receiptNumber,
    required this.date,
    required this.enteredBy,
    required this.clientCreatedAt,
    this.syncedAt,
    this.isDeleted = false,
    this.isNew = true,
  });

  bool get isSynced => syncedAt != null;

  factory Txn.create({
    required String type,
    required String category,
    required double amount,
    required String paymentMethod,
    required String enteredBy,
    String status = 'confirmed',
    String? description,
    String? receiptNumber,
    DateTime? date,
  }) {
    final now = DateTime.now();
    final d = date ?? now;
    final receipt = cleanText(receiptNumber);
    return Txn(
      id: const Uuid().v4(),
      type: type,
      category: category,
      amount: amount,
      paymentMethod: paymentMethod,
      status: status,
      description: cleanText(description),
      receiptNumber: receipt ?? generateReceiptNumber(now),
      date: DateTime(d.year, d.month, d.day),
      enteredBy: enteredBy,
      clientCreatedAt: now,
    );
  }

  /// Returns an edited copy. Identity (id, receipt, creation time) is
  /// preserved; [syncedAt] resets to null so the next sync upserts the
  /// changes. [isNew] is carried over, so an edited-but-never-synced row
  /// still sends `created_at` and an already-synced row does not.
  Txn applyEdit({
    required String type,
    required String category,
    required double amount,
    required String paymentMethod,
    required String status,
    String? description,
    String? receiptNumber,
    required DateTime date,
    required String enteredBy,
  }) {
    return Txn(
      id: id,
      type: type,
      category: category,
      categoryId: categoryId,
      amount: amount,
      paymentMethod: paymentMethod,
      status: status,
      description: cleanText(description),
      receiptNumber: cleanText(receiptNumber) ?? this.receiptNumber,
      date: DateTime(date.year, date.month, date.day),
      enteredBy: enteredBy,
      clientCreatedAt: clientCreatedAt,
      syncedAt: null,
      isNew: isNew,
    );
  }

  /// Offline-safe receipt: R-YYYYMMDD-HHMMSS-xxxx (unique enough for v1,
  /// the server still enforces UNIQUE so clashes surface on sync).
  static String generateReceiptNumber([DateTime? now]) {
    final t = now ?? DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    final suffix = const Uuid().v4().substring(0, 4).toUpperCase();
    return 'R-${t.year}${p2(t.month)}${p2(t.day)}-'
        '${p2(t.hour)}${p2(t.minute)}${p2(t.second)}-$suffix';
  }

  /// Trims free text and folds the placeholder values used in the paper
  /// ledger ("", " ", "N/a", "-", "na") to null so reports stay clean.
  static String? cleanText(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    const placeholders = {'n/a', 'na', '-', '--', 'none', 'null'};
    if (placeholders.contains(t.toLowerCase())) return null;
    return t;
  }

  /// Accepts what people actually type: Bengali digits, the taka sign,
  /// thousands separators, stray spaces and a trailing decimal point.
  static double? parseAmount(String? v) {
    if (v == null) return null;
    var s = v.trim();
    if (s.isEmpty) return null;
    const bengali = '০১২৩৪৫৬৭৮৯';
    for (var i = 0; i < bengali.length; i++) {
      s = s.replaceAll(bengali[i], '$i');
    }
    s = s.replaceAll('৳', '').replaceAll(',', '').replaceAll(RegExp(r'\s'), '');
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.startsWith('.')) s = '0$s';
    return double.tryParse(s);
  }

  static String? validateAmount(String? v) {
    if (v == null || v.trim().isEmpty) return 'Amount required';
    final a = parseAmount(v);
    if (a == null) return 'Invalid number';
    if (a <= 0) return 'Must be > 0';
    return null;
  }

  static String dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toLocalMap() => {
    'id': id,
    'type': type,
    'category': category,
    'category_id': categoryId,
    'amount': amount,
    'payment_method': paymentMethod,
    'status': status,
    'description': description,
    'receipt_number': receiptNumber,
    'date': dateKey(date),
    'entered_by': enteredBy,
    'client_created_at': clientCreatedAt.toIso8601String(),
    'synced_at': syncedAt?.toIso8601String(),
    'is_deleted': isDeleted ? 1 : 0,
    'is_new': isNew ? 1 : 0,
  };

  factory Txn.fromLocalMap(Map<String, dynamic> m) => Txn(
    id: m['id'] as String,
    type: m['type'] as String,
    category: (m['category'] as String?) ?? '',
    categoryId: m['category_id'] as String?,
    amount: (m['amount'] as num).toDouble(),
    paymentMethod: m['payment_method'] as String,
    status: m['status'] as String,
    description: m['description'] as String?,
    receiptNumber: m['receipt_number'] as String?,
    date: DateTime.parse(m['date'] as String),
    enteredBy: m['entered_by'] as String,
    clientCreatedAt: DateTime.parse(m['client_created_at'] as String),
    syncedAt: m['synced_at'] == null
        ? null
        : DateTime.parse(m['synced_at'] as String),
    isDeleted: (m['is_deleted'] as int? ?? 0) == 1,
    isNew: (m['is_new'] as int? ?? 1) == 1,
  );

  /// Payload for the Supabase `transactions` upsert. `created_at` is sent
  /// only for rows the server has never seen, so editing a synced
  /// transaction leaves its original creation timestamp intact.
  Map<String, dynamic> toSupabaseMap({String? resolvedCategoryId}) {
    final now = DateTime.now().toUtc().toIso8601String();
    return {
      'id': id,
      'type': type,
      'category_id': resolvedCategoryId ?? categoryId,
      'amount': amount,
      'payment_method': paymentMethod,
      'status': status,
      'description': description,
      'receipt_number': receiptNumber,
      'date': dateKey(date),
      'entered_by': enteredBy,
      'client_created_at': clientCreatedAt.toUtc().toIso8601String(),
      if (isNew) 'created_at': now,
      'updated_at': now,
      'is_deleted': isDeleted,
    };
  }
}
