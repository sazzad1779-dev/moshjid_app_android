import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/app_config.dart';

/// Supabase email+password auth for DB writes (authenticated role).
/// This is separate from the local shared PIN, which is only a device lock.
class AuthService {
  static const _enteredByCacheKey = 'moshjid_entered_by_id';

  SupabaseClient get _client => Supabase.instance.client;

  bool get isConfigured => AppConfig.isSupabaseConfigured;

  bool get isSignedIn => isConfigured && _client.auth.currentUser != null;

  String? get authUserId => _client.auth.currentUser?.id;

  String? get email => _client.auth.currentUser?.email;

  Future<void> signIn(String email, String password) async {
    await _client.auth.signInWithPassword(email: email.trim(), password: password);
    // Refresh cached entered_by right after login.
    await resolveEnteredById(forceRefresh: true);
  }

  /// Silent background sign-in using the service account from .env.
  /// Called at startup and before every sync. Returns true if a session
  /// exists afterwards. Never throws — sync stays offline-friendly.
  Future<bool> ensureSignedIn() async {
    if (!isConfigured) return false;
    if (_client.auth.currentUser != null) return true;
    if (!AppConfig.hasServiceCredentials) return false;
    try {
      await _client.auth.signInWithPassword(
        email: AppConfig.serviceEmail,
        password: AppConfig.servicePassword,
      );
      await resolveEnteredById(forceRefresh: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    final p = await SharedPreferences.getInstance();
    await p.remove(_enteredByCacheKey);
  }

  /// `transactions.entered_by` must be a `profiles.id`.
  /// Resolves it via `profiles.auth_user_id = auth user id`, caches locally
  /// (offline inserts need it too). Falls back to ENTERED_BY_ID from .env.
  Future<String> resolveEnteredById({bool forceRefresh = false}) async {
    final p = await SharedPreferences.getInstance();
    if (!forceRefresh) {
      final cached = p.getString(_enteredByCacheKey);
      if (cached != null && cached.isNotEmpty) return cached;
    }
    final fallback = AppConfig.enteredById;
    final uid = authUserId;
    if (uid == null) {
      if (fallback.isNotEmpty) return fallback;
      throw StateError('Not signed in');
    }
    try {
      final row = await _client
          .from('profiles')
          .select('id')
          .eq('auth_user_id', uid)
          .maybeSingle();
      final id = (row as Map?)?['id'] as String?;
      if (id != null && id.isNotEmpty) {
        await p.setString(_enteredByCacheKey, id);
        return id;
      }
    } catch (_) {
      // offline or RLS — fall through to cache/fallback
      final cached = p.getString(_enteredByCacheKey);
      if (cached != null && cached.isNotEmpty) return cached;
    }
    if (fallback.isNotEmpty &&
        fallback != '00000000-0000-0000-0000-000000000000') {
      return fallback;
    }
    final cached = p.getString(_enteredByCacheKey);
    if (cached != null && cached.isNotEmpty) return cached;
    throw StateError(
        'No linked profile: set profiles.auth_user_id = $uid for the mosque user.');
  }
}