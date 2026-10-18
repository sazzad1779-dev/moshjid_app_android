import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/models/name_key.dart';

/// Pins the cases where the Dart normalizer and the generated columns in
/// `tools/donor_dedupe.sql` would otherwise be free to drift apart.
///
/// Each `expect` below corresponds to a line of SQL. If you change one side,
/// change the other, and update the SQL comment.
void main() {
  group('nameKey', () {
    // lower(regexp_replace(btrim(coalesce(full_name,'')), '[[:space:]]+', ' ', 'g'))
    test('collapses internal whitespace runs to a single space', () {
      expect(NameKey.name('Taijul   Islam'), 'taijul islam');
    });

    test('trims leading and trailing whitespace', () {
      expect(NameKey.name('   Sazzad  '), 'sazzad');
    });

    test('lowercases', () {
      expect(NameKey.name('SHAMSUL BAPARY'), 'shamsul bapary');
    });

    test('handles tabs and newlines as whitespace', () {
      expect(NameKey.name('Roxi\t\nBapary'), 'roxi bapary');
    });

    test('null and blank become empty, not null', () {
      expect(NameKey.name(null), '');
      expect(NameKey.name('   '), '');
    });

    test('leaves Bengali untouched apart from case', () {
      expect(NameKey.name('মোহাম্মদ  শাহেদ'), 'মোহাম্মদ শাহেদ');
    });
  });

  group('nameKey: Unicode NFC', () {
    // Mirrors Postgres `normalize(x, NFC)` via the unorm_dart dependency. A
    // name that reaches the app decomposed -- pasted from a web page, a file
    // listing, or a different input method -- must still be one donor.

    /// 'e' + COMBINING ACUTE ACCENT: the canonical decomposition of 'e-acute'.
    const eAcute = 'e\u0301';

    /// The composed form of those same characters, U+00E9.
    const eAcuteComposed = '\u00E9';

    test('composes a decomposed name before comparing', () {
      expect(NameKey.name(eAcute), eAcuteComposed);
    });

    test('composed and decomposed spellings are one donor', () {
      expect(
        NameKey.match(name: eAcute, phone: null),
        NameKey.match(name: eAcuteComposed, phone: null),
      );
    });

    test('decomposed input is not returned decomposed', () {
      expect(eAcute.length, 2, reason: 'sanity: the input really is decomposed');
      expect(NameKey.name(eAcute).length, 1);
    });

    test('leaves Bengali alone', () {
      // Bangla has no case and its letters are already single code points, so
      // normalization is a no-op. That is the correct result, not a gap: two
      // Bangla spellings that differ are different words, and folding them
      // would be wrong.
      const bangla = '\u0995\u09CD\u09AF';
      expect(NameKey.name(bangla), bangla);
    });

    test('does NOT fold nukta sequences', () {
      // Documented deliberately. Devanagari KA + NUKTA has a *compatibility*
      // decomposition, so neither NFC nor NFKC composes it, and Bangla has no
      // precomposed equivalent at all. Switching to NFKC later would not change
      // this -- do not expect it to.
      const kaPlusNukta = '\u0915\u093C';
      expect(NameKey.name(kaPlusNukta), kaPlusNukta);
    });

    test('composition does not disturb ASCII', () {
      expect(NameKey.name('Taijul'), 'taijul');
    });
  });

  group('phoneKey', () {
    // See public.moshjid_phone_key() in tools/donor_dedupe.sql
    test('strips formatting characters', () {
      expect(NameKey.phone('01712-345 678'), '01712345678');
      expect(NameKey.phone('(017)12.345.678'), '01712345678');
    });

    test('returns null when there are no digits', () {
      expect(NameKey.phone(null), null);
      expect(NameKey.phone(''), null);
      expect(NameKey.phone('   '), null);
      expect(NameKey.phone('n/a'), null);
    });

    test('zero is a digit, not an empty phone', () {
      expect(NameKey.phone('0'), '0');
    });
  });

  group('phoneKey: Bangladesh country code', () {
    test('reduces +880 to local form', () {
      expect(NameKey.phone('+880 1712-345678'), '01712345678');
    });

    test('reduces a bare 880 prefix', () {
      expect(NameKey.phone('8801712345678'), '01712345678');
    });

    test('reduces a 00 international prefix', () {
      expect(NameKey.phone('008801712345678'), '01712345678');
    });

    test('adds a missing trunk zero to a bare national number', () {
      expect(NameKey.phone('1712345678'), '01712345678');
    });

    test('already-local numbers are left alone', () {
      expect(NameKey.phone('01712345678'), '01712345678');
    });

    test('every spelling of one number collapses to the same key', () {
      const spellings = [
        '01712345678',
        '01712-345678',
        '+8801712345678',
        '+880 1712 345678',
        '008801712345678',
        '880-1712-345678',
        '1712345678',
      ];
      final keys = spellings.map(NameKey.phone).toSet();
      expect(keys, {'01712345678'});
    });

    test('leaves an unrecognised shape alone rather than guessing', () {
      // 14 digits is neither local nor a known international form. Rewriting
      // it would risk merging two different people.
      expect(NameKey.phone('88017123456789'), '88017123456789');
      expect(NameKey.phone('12345'), '12345');
      expect(NameKey.phone('9991712345678'), '9991712345678');
    });
  });

  group('phoneKey: does not collide across people', () {
    test('two different local numbers stay different', () {
      expect(NameKey.phone('01712345678'), isNot(NameKey.phone('01719999999')));
    });

    test('the same local number written two ways is one donor', () {
      expect(
        NameKey.match(name: 'Roxi Bapary', phone: '01712-345678'),
        NameKey.match(name: 'roxi  bapary', phone: '+8801712345678'),
      );
    });

    test('phone wins: same name, one with a phone, are different donors', () {
      final withPhone = NameKey.match(name: 'Roxi', phone: '01712345678');
      final without = NameKey.match(name: 'Roxi', phone: null);
      expect(withPhone, isNot(without));
    });
  });

  group('matchKey', () {
    test('a donor with a phone is keyed by phone', () {
      expect(NameKey.match(name: 'Ali', phone: '01712345678'), 'p:01712345678');
    });

    test('a donor without a phone is keyed by name', () {
      expect(NameKey.match(name: 'Ali', phone: null), 'n:ali');
      expect(NameKey.match(name: 'Ali', phone: ''), 'n:ali');
      expect(NameKey.match(name: 'Ali', phone: 'n/a'), 'n:ali');
    });

    test('name and phone key spaces cannot collide', () {
      expect(NameKey.match(name: 'p:123', phone: null), 'n:p:123');
      expect(NameKey.match(name: 'x', phone: '123'), 'p:123');
    });

    test('phone wins: same name, one with a phone, are different donors', () {
      final withPhone = NameKey.match(name: 'Roxi', phone: '01712345678');
      final without = NameKey.match(name: 'Roxi', phone: null);
      expect(withPhone, isNot(without));
    });

    test('phone wins: same phone, different spellings, are the same donor', () {
      expect(
        NameKey.match(name: 'Roxi Bapary', phone: '01712-345678'),
        NameKey.match(name: 'roxi  bapary', phone: '01712 345678'),
      );
    });

    test('same name and no phone is the same donor', () {
      expect(
        NameKey.match(name: '  Taijul  ISLAM ', phone: null),
        NameKey.match(name: 'taijul islam', phone: null),
      );
    });

    test('different names without phones are different donors', () {
      expect(
        NameKey.match(name: 'Shorif', phone: null),
        isNot(NameKey.match(name: 'Roman', phone: null)),
      );
    });

    test('is case and whitespace insensitive across a real pair', () {
      expect(
        NameKey.same(nameA: ' Mustafizur  Rahman Shuvo ', phoneA: null,
            nameB: 'mustafizur rahman shuvo', phoneB: null),
        isTrue,
      );
      expect(
        NameKey.same(nameA: 'Taijul Islam', phoneA: null,
            nameB: 'Taijul Islam', phoneB: '01712345678'),
        isFalse,
        reason: 'supplying a phone makes it a different donor');
    });
  });

  group('rank', () {
    test('prefix beats substring beats miss', () {
      expect(NameKey.rank('taijul islam', 'taij'), 0);
      expect(NameKey.rank('taijul islam', 'islam'), 1);
      expect(NameKey.rank('taijul islam', 'zzz'), 2);
    });

    test('is case insensitive', () {
      expect(NameKey.rank('Taijul Islam', 'TAIJ'), 0);
    });
  });

  group('filter', () {
    test('prefix matches sort before substring matches', () {
      final names = ['islam khan', 'taijul islam', 'shariful islam'];
      final out = NameKey.filter(names, 'islam', (e) => e);
      // 'islam khan' *starts with* the query; the other two only contain it.
      expect(out.first, 'islam khan');
      expect(out, hasLength(3));
      expect(out.skip(1), containsAll(['taijul islam', 'shariful islam']));
    });

    test('prefix beats substring on the query, not the name', () {
      final names = ['islam khan', 'taijul islam'];
      final out = NameKey.filter(names, 'islam', (e) => e);
      expect(out.first, 'islam khan');

      final byName = NameKey.filter(['ali hassan', 'z faruque'], 'ali', (e) => e);
      expect(byName, ['ali hassan']);
    });

    test('empty query returns the input untouched', () {
      final names = ['b', 'a'];
      expect(NameKey.filter(names, '  ', (e) => e), names);
    });

    test('drops non-matches', () {
      expect(NameKey.filter(['ali', 'roxi'], 'zzz', (e) => e), isEmpty);
    });
  });
}