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

  /// `profiles.id` of the donor, for monthly-giver categories.
  ///
  /// May point at a profile that only exists on this device yet. [SyncService]
  /// pushes profiles first, then rewrites this to the canonical server id before
  /// the transaction goes up, so the server never sees a dangling member_id.
  final String? memberId;

  /// Denormalised from [memberId]'s profile. Kept on the row because the
  /// server-side importer populates `transactions.donor_name` directly from
  /// Excel, and reports read it without a join.
  final String? donorName;
  final String? donorPhone;

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
    this.memberId,
    this.donorName,
    this.donorPhone,
    required this.clientCreatedAt,
    this.syncedAt,
    this.isDeleted = false,
  });

  bool get isSynced => syncedAt != null;

  bool get hasDonor => memberId != null || (donorName?.trim().isNotEmpty ?? false);

  factory Txn.create({
    required String type,
    required String category,
    String? categoryId,
    required double amount,
    required String paymentMethod,
    required String enteredBy,
    String status = 'confirmed',
    String? description,
    String? receiptNumber,
    DateTime? date,
    String? memberId,
    String? donorName,
    String? donorPhone,
  }) {
    final now = DateTime.now();
    return Txn(
      id: const Uuid().v4(),
      type: type,
      category: category,
      categoryId: categoryId,
      amount: amount,
      paymentMethod: paymentMethod,
      status: status,
      description: (description?.trim().isEmpty ?? true) ? null : description!.trim(),
      receiptNumber: (receiptNumber?.trim().isEmpty ?? true)
          ? generateReceiptNumber(now)
          : receiptNumber!.trim(),
      date: DateTime((date ?? now).year, (date ?? now).month, (date ?? now).day),
      enteredBy: enteredBy,
      memberId: memberId,
      donorName: (donorName?.trim().isEmpty ?? true) ? null : donorName!.trim(),
      donorPhone: (donorPhone?.trim().isEmpty ?? true) ? null : donorPhone!.trim(),
      clientCreatedAt: now,
    );
  }

  /// Returns an edited copy. Identity (id, receipt, history) is preserved;
  /// [syncedAt] resets to null so the next sync upserts the changes.
  Txn applyEdit({
    required String type,
    required String category,
    String? categoryId,
    required double amount,
    required String paymentMethod,
    required String status,
    String? description,
    String? receiptNumber,
    required DateTime date,
    required String enteredBy,
    String? memberId,
    String? donorName,
    String? donorPhone,
  }) {
    return Txn(
      id: id,
      type: type,
      category: category,
      categoryId: categoryId ?? this.categoryId,
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
      memberId: memberId ?? this.memberId,
      donorName: (donorName?.trim().isEmpty ?? true) ? null : donorName!.trim(),
      donorPhone: (donorPhone?.trim().isEmpty ?? true) ? null : donorPhone!.trim(),
      clientCreatedAt: clientCreatedAt,
      syncedAt: null,
    );
  }

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
        'member_id': memberId,
        'donor_name': donorName,
        'donor_phone': donorPhone,
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
        memberId: m['member_id'] as String?,
        donorName: m['donor_name'] as String?,
        donorPhone: m['donor_phone'] as String?,
        clientCreatedAt: DateTime.parse(m['client_created_at'] as String),
        syncedAt: m['synced_at'] == null
            ? null
            : DateTime.parse(m['synced_at'] as String),
        isDeleted: (m['is_deleted'] as int? ?? 0) == 1,
      );

  /// Payload for Supabase `transactions` upsert.
  ///
  /// `type` is intentionally absent: the column was dropped from the server
  /// table and is now derived from `transaction_categories.type` via
  /// `category_id`. It is still kept locally so the list can colour and total
  /// rows offline, before any category cache exists.
  ///
  /// [memberId] is passed in rather than read from the row because a donor
  /// created offline holds a local uuid that only becomes a real profile id once
  /// `pushProfiles` has run. Sending the local id here would create a dangling
  /// reference server-side.
  Map<String, dynamic> toSupabaseMap({
    String? resolvedCategoryId,
    String? resolvedMemberId,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    return {
      'id': id,
      'category_id': resolvedCategoryId ?? categoryId,
      'member_id': resolvedMemberId ?? memberId,
      'donor_name': donorName,
      'donor_phone': donorPhone,
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