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
    return Txn(
      id: const Uuid().v4(),
      type: type,
      category: category,
      amount: amount,
      paymentMethod: paymentMethod,
      status: status,
      description: (description?.trim().isEmpty ?? true) ? null : description!.trim(),
      receiptNumber: (receiptNumber?.trim().isEmpty ?? true)
          ? generateReceiptNumber(now)
          : receiptNumber!.trim(),
      date: DateTime((date ?? now).year, (date ?? now).month, (date ?? now).day),
      enteredBy: enteredBy,
      clientCreatedAt: now,
    );
  }

  /// Returns an edited copy. Identity (id, receipt, history) is preserved;
  /// [syncedAt] resets to null so the next sync upserts the changes.
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
      description:
          (description?.trim().isEmpty ?? true) ? null : description!.trim(),
      receiptNumber: (receiptNumber?.trim().isEmpty ?? true)
          ? this.receiptNumber
          : receiptNumber!.trim(),
      date: DateTime(date.year, date.month, date.day),
      enteredBy: enteredBy,
      clientCreatedAt: clientCreatedAt,
      syncedAt: null,
    );
  }
  /// server still enforces UNIQUE so clashes surface on sync).
  /// Offline-safe receipt: R-YYYYMMDD-HHMMSS-xxxx (unique enough for v1,
  /// server still enforces UNIQUE so clashes surface on sync).
  static String generateReceiptNumber([DateTime? now]) {
    final t = now ?? DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    final suffix = const Uuid().v4().substring(0, 4).toUpperCase();
    return 'R-${t.year}${p2(t.month)}${p2(t.day)}-${p2(t.hour)}${p2(t.minute)}${p2(t.second)}-$suffix';
  }

  static String? validateAmount(String? v) {
    if (v == null || v.trim().isEmpty) return 'Amount required';
    final a = double.tryParse(v.trim());
    if (a == null) return 'Invalid number';
    if (a <= 0) return 'Must be > 0';
    return null;
  }

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
        'date': '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}',
        'entered_by': enteredBy,
        'client_created_at': clientCreatedAt.toIso8601String(),
        'synced_at': syncedAt?.toIso8601String(),
        'is_deleted': isDeleted ? 1 : 0,
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
      );

  /// Payload for Supabase `transactions` upsert.
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
      'date': '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}',
      'entered_by': enteredBy,
      'client_created_at': clientCreatedAt.toUtc().toIso8601String(),
      'created_at': now,
      'updated_at': now,
      'is_deleted': isDeleted,
    };
  }
}