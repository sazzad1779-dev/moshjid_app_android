import 'package:unorm_dart/unorm_dart.dart';

/// Donor identity keys.
///
/// These must produce byte-identical output to the SQL functions
/// `public.moshjid_name_key` / `public.moshjid_phone_key` created by
/// `tools/donor_dedupe.sql`. If the two ever disagree, the app inserts a
/// profile the server then folds away, and the donor shows up twice in the
/// dropdown with one copy unreachable.
///
/// The contract, restated from the SQL:
///
///  * A donor **with a phone number** is identified by that number, reduced to
///    Bangladeshi local form so `+880 1712-345678`, `008801712345678` and
///    `01712-345678` are one person.
///  * A donor **without a phone number** is identified by their name: NFC
///    normalized, lowercased, with whitespace runs collapsed.
///  * The phone always wins. Two rows may share a name if at least one of them
///    supplied a phone.
///  * When two rows collide, the earliest one survives.
///
/// `test/name_key_test.dart` pins the cases that are easy to get wrong.
class NameKey {
  const NameKey._();

  /// Postgres `[[:space:]]+`. Dart's `\s` is unicode-aware and covers the same
  /// set under a UTF-8 collation.
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Postgres `[^0-9]`. ASCII digits only -- Bengali numerals are deliberately
  /// rejected, so they fall through to name matching rather than producing a key
  /// that looks valid but collides across scripts.
  static final RegExp _nonDigit = RegExp(r'[^0-9]');

  /// The only country code this mosque's donors use.
  static const _dialCode = '880';

  /// Normalized name: NFC, lowercased, whitespace collapsed.
  ///
  /// Returns '' for null/blank input; callers that need to reject blank names
  /// should check for ''.
  ///
  /// NFC runs first so a name pasted from a source that composes Bengali
  /// conjuncts differently still matches the same person typed on the keypad.
  /// Postgres does this with `normalize(x, NFC)` (PG 13+).
  static String name(String? raw) {
    final composed = nfc(raw ?? '');
    return composed.trim().replaceAll(_whitespace, ' ').toLowerCase();
  }

  /// Bangladeshi phone number in local form, or null when there are no digits.
  ///
  /// Reduction is deliberately conservative: only the exact shapes listed below
  /// are rewritten. A number in an unexpected format is left as its bare digits
  /// rather than being guessed at, because a wrong guess silently merges two
  /// different people into one donor.
  ///
  ///   1. strip every non-digit
  ///   2. drop a leading `00` international prefix
  ///   3. `880` + 10 digits  ->  `0` + those 10 digits   (country code out, trunk 0 in)
  ///   4. `1` + 9 digits     ->  `0` + all 10 digits     (bare national number)
  ///
  /// Null and '' both mean "no phone", which routes the donor to name matching.
  static String? phone(String? raw) {
    var d = (raw ?? '').replaceAll(_nonDigit, '');
    if (d.isEmpty) return null;

    if (d.startsWith('00')) {
      d = d.substring(2);
    }
    if (d.length == 13 && d.startsWith(_dialCode)) {
      d = '0${d.substring(_dialCode.length)}';
    } else if (d.length == 10 && d.startsWith('1')) {
      d = '0$d';
    }
    return d;
  }

  /// The identity key stored in `profiles.match_key` and `profiles_cache.match_key`.
  /// Prefixed `p:` or `n:` so the two key spaces can never collide.
  static String match({required String? name, required String? phone}) {
    final p = phoneKey(phone);
    return p != null ? 'p:$p' : 'n:${nameKey(name)}';
  }

  static String nameKey(String? raw) => name(raw);
  static String? phoneKey(String? raw) => phone(raw);

  /// True when two donors are the same person under the rule above.
  static bool same({
    required String? nameA,
    String? phoneA,
    required String? nameB,
    String? phoneB,
  }) =>
      match(name: nameA, phone: phoneA) ==
      match(name: nameB, phone: phoneB);

  /// Case/whitespace-insensitive "starts with", then "contains", then anything.
  /// Drives the ordering of the donor picker's result list.
  static int rank(String haystack, String needle) {
    final h = name(haystack);
    final n = name(needle);
    if (n.isEmpty) return 2;
    if (h.startsWith(n)) return 0;
    if (h.contains(n)) return 1;
    return 2;
  }

  /// Filters and orders [items] by [keyFn] for the picker. Items whose key
  /// ranks 2 are dropped, so callers that want fuzzy matches appended should
  /// call this per page rather than over the whole table.
  static List<T> filter<T>(List<T> items, String query, String Function(T) keyFn) {
    if (query.trim().isEmpty) return items;
    final matched = items.where((e) => rank(keyFn(e), query) < 2).toList();
    matched.sort((a, b) {
      final r = rank(keyFn(a), query).compareTo(rank(keyFn(b), query));
      return r != 0 ? r : name(keyFn(a)).compareTo(name(keyFn(b)));
    });
    return matched;
  }
}