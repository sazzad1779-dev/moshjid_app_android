import 'name_key.dart';

/// A donor, or an operator. Mirrors the subset of the Supabase `profiles`
/// table the app reads and writes.
///
/// ## Identity
///
/// [id] is the device's own stable handle for a person and never changes. It is
/// what `transactions_local.member_id` always points at, including for donors
/// that came down from the cloud.
///
/// [remoteId] is the `profiles.id` uuid on the server, or null while the donor
/// has never been pushed. It is null for *every* freshly pulled row too: a
/// cloud donor gets a fresh local id and records its server uuid in [remoteId].
///
/// Keeping those two separate is what makes a server-side merge safe. When two
/// devices independently create "Roxi", the server keeps one row and folds the
/// other away, so this device's pending donor is told to adopt someone else's
/// [remoteId] instead of rewriting its own [id] and orphaning every
/// transaction that referenced it. Nothing has to be repointed.
///
/// ## Sync state
///
/// [syncedAt] null means [remoteId] is unknown, i.e. the donor exists only on
/// this device.
class Profile {
  final String id;
  final String? remoteId;
  final String fullName;
  final String? phone;
  final String role;
  final String status;

  /// Donors who commit to giving every month. Existing rows default to true;
  /// only set it false once there is a reason to track the distinction.
  final bool isMonthly;

  final String source;
  final DateTime clientCreatedAt;
  final DateTime? syncedAt;

  const Profile({
    required this.id,
    this.remoteId,
    required this.fullName,
    this.phone,
    this.role = ProfileRole.member,
    this.status = ProfileStatus.approved,
    this.isMonthly = true,
    this.source = ProfileSource.local,
    required this.clientCreatedAt,
    this.syncedAt,
  });

  /// Donors and operators share one table, but only donors belong in the picker.
  /// An operator is a `collector`/`admin`, never a `member`.
  static const memberRole = 'member';
  static const collectorRole = 'collector';
  static const adminRole = 'admin';

  /// `profiles.status` in the schema. `link_donor_profiles.py` writes
  /// `status = 'active'` while `approval_status = 'approved'`; both columns
  /// exist server-side and this app only reads `status`.
  static const activeStatus = 'active';
  static const approvedStatus = 'approved';

  /// Locally created, not yet on the server.
  static const localSource = 'local';

  /// Came down from the server in a pull.
  static const cloudSource = 'cloud';

  bool get isPending => syncedAt == null || remoteId == null;
  bool get isMember => role == memberRole;

  /// Identity per [NameKey]. Must match `profiles.match_key` exactly.
  String get matchKey => NameKey.match(name: fullName, phone: phone);

  String get nameKey => NameKey.name(fullName);
  String? get phoneKey => NameKey.phone(phone);

  /// What to show in the picker. Falls back to the raw name only if it is
  /// somehow blank, which [validate] rules out at creation time.
  String get displayName => fullName.trim();

  /// A donor is only a duplicate if their *identity* repeats, not their name.
  bool isSameDonorAs({String? name, String? phone}) =>
      matchKey == NameKey.match(name: name, phone: phone);

  static String? validateName(String? v) {
    if (v == null || v.trim().isEmpty) return 'Name required';
    if (v.trim().length < 2) return 'Too short';
    return null;
  }

  /// Optional, but validated loosely so an unparseable number never becomes a
  /// phone key that no donor can ever match.
  static String? validatePhone(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    if (NameKey.phone(t) == null) return 'Digits only';
    if (t.replaceAll(RegExp(r'\s'), '').length < 6) return 'Too short';
    return null;
  }

  Profile copyWith({
    String? id,
    String? remoteId,
    String? fullName,
    String? phone,
    bool clearPhone = false,
    String? role,
    String? status,
    bool? isMonthly,
    String? source,
    DateTime? clientCreatedAt,
    DateTime? syncedAt,
  }) =>
      Profile(
        id: id ?? this.id,
        remoteId: remoteId ?? this.remoteId,
        fullName: fullName ?? this.fullName,
        phone: clearPhone ? null : (phone ?? this.phone),
        role: role ?? this.role,
        status: status ?? this.status,
        isMonthly: isMonthly ?? this.isMonthly,
        source: source ?? this.source,
        clientCreatedAt: clientCreatedAt ?? this.clientCreatedAt,
        syncedAt: syncedAt ?? this.syncedAt,
      );

  /// Builds a donor the user just typed into the form. The caller generates
  /// [id]; [LocalDb] refuses to insert when [matchKey] already exists so that
  /// typing the same name twice offline yields one row.
  factory Profile.create({
    required String id,
    required String fullName,
    String? phone,
    String role = memberRole,
    String status = approvedStatus,
    bool isMonthly = true,
    DateTime? clientCreatedAt,
  }) =>
      Profile(
        id: id,
        fullName: fullName.trim(),
        phone: (phone?.trim().isEmpty ?? true) ? null : phone!.trim(),
        role: role,
        status: status,
        isMonthly: isMonthly,
        source: localSource,
        clientCreatedAt: clientCreatedAt ?? DateTime.now(),
      );

  // ---- serialisation ----

  Map<String, dynamic> toLocalMap() => {
        'id': id,
        'remote_id': remoteId,
        'full_name': fullName,
        'name_key': nameKey,
        'phone': phone,
        'phone_key': phoneKey,
        'match_key': matchKey,
        'role': role,
        'status': status,
        'is_monthly': isMonthly ? 1 : 0,
        'source': source,
        'client_created_at': clientCreatedAt.toIso8601String(),
        'synced_at': syncedAt?.toIso8601String(),
      };

  factory Profile.fromLocalMap(Map<String, dynamic> m) => Profile(
        id: m['id'] as String,
        remoteId: m['remote_id'] as String?,
        fullName: (m['full_name'] as String?) ?? '',
        phone: m['phone'] as String?,
        role: (m['role'] as String?) ?? memberRole,
        status: (m['status'] as String?) ?? approvedStatus,
        isMonthly: (m['is_monthly'] as int? ?? 1) == 1,
        source: (m['source'] as String?) ?? localSource,
        clientCreatedAt: DateTime.parse(m['client_created_at'] as String),
        syncedAt:
            m['synced_at'] == null ? null : DateTime.parse(m['synced_at'] as String),
      );

/// Row shape returned by a `select` against `profiles`.
  ///
  /// [localId] is this device's stable handle for the donor; it is *not* the
  /// server's `profiles.id`. That goes into [remoteId]. Transactions reference
  /// [localId], which never changes even if the server later merges this donor
  /// into another row.
  ///
  /// Every column is read defensively, so a row is still usable if the server
  /// has not had `tools/donor_dedupe.sql` applied yet and lacks `phone` or
  /// `is_monthly`.
  ///
  /// The server's own `name_key` / `match_key` are deliberately ignored: those
  /// are generated columns that [Profile.matchKey] recomputes from the same
  /// full name and phone. If the two implementations ever disagree, a test in
  /// `test/name_key_test.dart` says so -- silently trusting one side would
  /// hide the divergence until a donor appeared twice in the dropdown.
  factory Profile.fromSupabase(
    Map<String, dynamic> m, {
    required String localId,
  }) =>
      Profile(
        id: localId,
        remoteId: m['id'] as String?,
        fullName: (m['full_name'] as String?) ?? '',
        phone: m['phone'] as String?,
        role: (m['role'] as String?) ?? memberRole,
        status: (m['status'] as String?) ?? approvedStatus,
        isMonthly: m['is_monthly'] as bool? ?? true,
        source: cloudSource,
        clientCreatedAt:
            DateTime.tryParse((m['client_created_at'] ?? m['created_at'] ?? '') as String)
                    ?.toLocal() ??
                DateTime.now(),
        syncedAt: DateTime.now(),
      );

  /// Payload for the `profiles` upsert.
  ///
  /// Sends [remoteId] as the server's `id`, not [id]: a donor that has never
  /// been pushed has no remote id yet, and in that case the row is inserted
  /// with [id] so the server and this device agree from the first upload. See
  /// [pushId].
  ///
  /// Deliberately excludes `name_key` and `match_key`: Postgres computes them,
  /// and sending them fails against a generated column.
  Map<String, dynamic> toSupabaseMap() {
    final now = DateTime.now().toUtc().toIso8601String();
    return {
      'id': pushId,
      'full_name': fullName,
      'phone': phone,
      'role': role,
      'status': status,
      'is_monthly': isMonthly,
      'client_created_at': clientCreatedAt.toUtc().toIso8601String(),
      'created_at': now,
      'updated_at': now,
    };
  }

  /// The uuid to use as `profiles.id` when pushing.
  ///
  /// A donor that has never reached the server is inserted under its own local
  /// id, so the two agree immediately and no second round trip is needed. Once
  /// the server has assigned or adopted an id, that is authoritative.
  String get pushId => remoteId ?? id;

  @override
  String toString() =>
      'Profile($fullName${phone == null ? '' : ' / $phone'}, $role, '
      '${syncedAt == null ? 'pending' : 'synced'})';
}

/// Role and status literals, in one place so a typo is a compile error.
class ProfileRole {
  const ProfileRole._();
  static const member = Profile.memberRole;
  static const collector = Profile.collectorRole;
  static const admin = Profile.adminRole;
}

class ProfileStatus {
  const ProfileStatus._();
  static const active = Profile.activeStatus;
  static const approved = Profile.approvedStatus;
}

class ProfileSource {
  const ProfileSource._();
  static const local = Profile.localSource;
  static const cloud = Profile.cloudSource;
}