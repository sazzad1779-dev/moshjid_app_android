// Central v1 configuration.
//
// Priority: --dart-define > .env > placeholder.
// .env keys: SUPABASE_URL, SUPABASE_ANON_KEY, ENTERED_BY_ID (optional).
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  static const _defineUrl = String.fromEnvironment('SUPABASE_URL',
      defaultValue: '');
  static const _defineKey = String.fromEnvironment('SUPABASE_ANON_KEY',
      defaultValue: '');
  static const _defineEnteredBy = String.fromEnvironment('ENTERED_BY_ID',
      defaultValue: '');
  static const _defineServiceEmail = String.fromEnvironment('SERVICE_EMAIL',
      defaultValue: '');
  static const _defineServicePassword = String.fromEnvironment(
      'SERVICE_PASSWORD',
      defaultValue: '');

  static String get supabaseUrl {
    if (_defineUrl.isNotEmpty) return _defineUrl;
    if (dotenv.isInitialized) {
      final v = (dotenv.env['SUPABASE_URL'] ?? '').trim();
      if (v.isNotEmpty) return v;
    }
    return 'PASTE_SUPABASE_URL_HERE';
  }

  static String get supabaseAnonKey {
    if (_defineKey.isNotEmpty) return _defineKey;
    if (dotenv.isInitialized) {
      final v = (dotenv.env['SUPABASE_ANON_KEY'] ?? '').trim();
      if (v.isNotEmpty) return v;
    }
    return 'PASTE_SUPABASE_ANON_KEY_HERE';
  }

  static bool get isSupabaseConfigured =>
      supabaseUrl.startsWith('http') && supabaseAnonKey.length > 20;

  /// Single shared PIN for v1 (stored/compared locally).
  /// Change it here before distributing the APK, or change in-app via menu.
  static const defaultPin = '1234';

  /// `transactions.entered_by` is NOT NULL uuid in your schema.
  /// With shared-PIN login there is no auth user, so send a fixed
  /// service-user id. Create one row in `profiles` and paste its id here
  /// (or set ENTERED_BY_ID in .env / --dart-define).
  /// Example SQL: insert into profiles (id, full_name, role, status, joined_at)
  /// values (gen_random_uuid(), 'Mosque Device', 'collector', 'active', now())
  /// returning id;
  static String get enteredById {
    if (_defineEnteredBy.isNotEmpty) return _defineEnteredBy;
    if (dotenv.isInitialized) {
      final v = (dotenv.env['ENTERED_BY_ID'] ?? '').trim();
      if (v.isNotEmpty) return v;
    }
    return '00000000-0000-0000-0000-000000000000';
  }

  /// Hidden service account used silently for Supabase writes.
  /// The app UI stays PIN-only; these creds never show on screen.
  /// Set SERVICE_EMAIL / SERVICE_PASSWORD in .env (gitignored) or --dart-define.
  static String get serviceEmail {
    if (_defineServiceEmail.isNotEmpty) return _defineServiceEmail;
    if (dotenv.isInitialized) {
      final v = (dotenv.env['SERVICE_EMAIL'] ?? '').trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  static String get servicePassword {
    if (_defineServicePassword.isNotEmpty) return _defineServicePassword;
    if (dotenv.isInitialized) {
      final v = (dotenv.env['SERVICE_PASSWORD'] ?? '').trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  static bool get hasServiceCredentials =>
      serviceEmail.contains('@') && servicePassword.isNotEmpty;

  // ---- Enum values (must match DB exactly) ----
  static const txnTypes = ['income', 'expense', 'other'];
  static const paymentMethods = ['cash', 'bkash', 'nagad', 'bank', 'card', 'other'];
  static const defaultStatus = 'confirmed';

  /// Offline fallback for the category picker, used only until the first
  /// successful `refreshCategories()` populates the local cache.
  ///
  /// Must stay in lockstep with `CANONICAL` in `tools/sync_categories.py` --
  /// these are the same categories, split by type. Names differ from the server
  /// and `resolveCategoryId` returns null, so the transaction lands without a
  /// `category_id` until the next pull.
  static const Map<String, List<String>> seedCategories = {
    'income': [
      'Friday Collection',
      'Regular Donation',
      'Magrib Donation',
      'Donation (Outside Box)',
      'Imam Hadiya',
      'Other',
    ],
    'expense': [
      'Electricity Bill',
      'Imam Hadiya',
      'Maintenance',
      'Other',
    ],
    'other': ['Other Income', 'Other Expense'],
  };

  /// Categories whose rows are attributed to a named donor.
  ///
  /// Keyed on (name, type), never name alone: "Imam Hadiya" exists under both
  /// types and only the income side has donors. The income side is money coming
  /// in from monthly givers; the expense side is the imam's own payout and has
  /// nobody to attribute. Must stay in lockstep with `DONOR_CATEGORIES` in
  /// `tools/sync_categories.py`.
  static const Set<String> donorCategories = {'Imam Hadiya|income'};

  /// Whether a transaction in this category should offer the donor picker.
  static bool categoryTakesDonor(String name, String type) =>
      donorCategories.contains('$name|$type');
}