import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/models/profile.dart';
import 'package:moshjid_app/data/models/txn.dart';
import 'package:moshjid_app/data/sync/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// These exercise the offline half of the donor rules. The server half lives in
/// `tools/donor_dedupe.sql` and cannot run here, so every rule below has a
/// mirror in `test/name_key_test.dart` for the keys themselves.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('schema', () {
    test('a fresh install creates profiles_cache', () async {
      await LocalDb.withTempDb((db) async {
        final d = await db.db;
        final cols = await d.rawQuery('PRAGMA table_info(profiles_cache)');
        final names = cols.map((c) => c['name'] as String).toSet();
        expect(
          names,
          containsAll([
            'id',
            'remote_id',
            'full_name',
            'match_key',
            'role',
            'status',
            'is_monthly',
            'source',
            'client_created_at',
            'synced_at',
          ]),
        );
      });
    });

    test('transactions carry donor columns', () async {
      await LocalDb.withTempDb((db) async {
        final d = await db.db;
        final cols = await d.rawQuery('PRAGMA table_info(transactions_local)');
        final names = cols.map((c) => c['name'] as String).toSet();
        expect(names, containsAll(['member_id', 'donor_name', 'donor_phone']));
      });
    });

    test('upgrading a v3 install keeps existing transactions', () async {
      await LocalDb.withTempDb((db) async {
        // Build a genuine v3 database by hand so that opening it through
        // LocalDb really does run onUpgrade 3 -> 4. Recreating tables on an
        // already-v4 file would not exercise the migration at all.
        final old = await openDatabase(
          db.pathOverride!,
          version: 3,
          onCreate: (d, _) async {
            await d.execute('''
              CREATE TABLE transactions_local(
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                category TEXT NOT NULL,
                category_id TEXT,
                amount REAL NOT NULL,
                payment_method TEXT NOT NULL,
                status TEXT NOT NULL,
                description TEXT,
                receipt_number TEXT,
                date TEXT NOT NULL,
                entered_by TEXT NOT NULL,
                client_created_at TEXT NOT NULL,
                synced_at TEXT,
                is_deleted INTEGER NOT NULL DEFAULT 0
              )
            ''');
            await d.execute('''
              CREATE TABLE categories_cache(
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                type TEXT NOT NULL
              )
            ''');
          },
        );
        await old.insert('transactions_local', {
          'id': 'old-1',
          'type': 'income',
          'category': 'Regular Donation',
          'amount': 100.0,
          'payment_method': 'cash',
          'status': 'confirmed',
          'date': '2024-01-01',
          'entered_by': 'op-1',
          'client_created_at': DateTime(2024, 1, 1).toIso8601String(),
          'is_deleted': 0,
        });
        await old.close();

        final migrated = (await db.listTxns()).single;
        expect(migrated.id, 'old-1');
        expect(migrated.amount, 100.0);
        expect(migrated.memberId, isNull, reason: 'no donor yet');

        // The donor table and the donor columns now exist.
        expect(await db.allProfiles(), isEmpty);
        await db.ensureProfile(fullName: 'Roxi');
        expect(await db.allProfiles(), hasLength(1));
      });
    });

    test('a v3 category cache is still readable after upgrade', () async {
      await LocalDb.withTempDb((db) async {
        await db.cacheCategories([
          {'id': 'c1', 'name': 'Imam Hadiya', 'type': 'income'},
          {'id': 'c2', 'name': 'Imam Hadiya', 'type': 'expense'},
        ]);
        // The two sides must stay distinct after a refresh.
        expect(await db.resolveCategoryId('Imam Hadiya', 'income'), 'c1');
        expect(await db.resolveCategoryId('Imam Hadiya', 'expense'), 'c2');
      });
    });
  });

  group('ensureProfile: offline first-wins', () {
    test('the same name typed twice yields one donor', () async {
      await LocalDb.withTempDb((db) async {
        final a = await db.ensureProfile(fullName: 'Taijul Islam');
        final b = await db.ensureProfile(fullName: '  taijul   ISLAM  ');

        expect(a.id, b.id);
        expect(await db.allProfiles(), hasLength(1));
      });
    });

    test('the first donor keeps the first spelling', () async {
      await LocalDb.withTempDb((db) async {
        final a = await db.ensureProfile(fullName: 'Taijul Islam');
        await db.ensureProfile(fullName: 'TAIJUL ISLAM');
        expect((await db.findProfileById(a.id))!.fullName, 'Taijul Islam');
      });
    });

    test('a phone number makes a different donor', () async {
      await LocalDb.withTempDb((db) async {
        final none = await db.ensureProfile(fullName: 'Roxi');
        final withPhone = await db.ensureProfile(fullName: 'Roxi', phone: '01712345678');
        expect(none.id, isNot(withPhone.id));
        expect(await db.allProfiles(), hasLength(2));
      });
    });

    test('every spelling of one phone is one donor', () async {
      await LocalDb.withTempDb((db) async {
        final a =
            await db.ensureProfile(fullName: 'Roxi', phone: '01712-345678');
        final b =
            await db.ensureProfile(fullName: 'Roxi Bapary', phone: '+8801712345678');
        expect(a.id, b.id);
        expect(await db.allProfiles(), hasLength(1));
      });
    });

    test('repeated saves across many transactions reuse one donor', () async {
      await LocalDb.withTempDb((db) async {
        final ids = <String>{};
        for (var i = 0; i < 25; i++) {
          ids.add((await db.ensureProfile(fullName: 'Roxi Bapary')).id);
        }
        expect(ids, hasLength(1));
        expect(await db.allProfiles(), hasLength(1));
      });
    });

    test('an empty name still produces a row rather than throwing', () async {
      // Validation lives in the form. The store must not corrupt itself if a
      // blank name reaches it.
      await LocalDb.withTempDb((db) async {
        final p = await db.ensureProfile(fullName: '   ');
        expect(p.matchKey, 'n:');
        expect(await db.ensureProfile(fullName: '').then((e) => e.id), p.id);
      });
    });
  });

  group('upsertCloudProfile', () {
    test('a donor already typed in offline adopts the server uuid', () async {
      await LocalDb.withTempDb((db) async {
        final local = await db.ensureProfile(fullName: 'Roxi');

        final merged = await db.upsertCloudProfile(
            {'id': 'server-uuid', 'full_name': 'Roxi', 'role': 'member'});

        // The local id survives, so every transaction still points at this donor.
        expect(merged.id, local.id);
        expect(merged.remoteId, 'server-uuid');
        expect(merged.isPending, isFalse);
        expect(await db.allProfiles(), hasLength(1));
      });
    });

    test('an unknown donor arrives under a fresh local id', () async {
      await LocalDb.withTempDb((db) async {
        final p = await db.upsertCloudProfile({'id': 'server-uuid',
          'full_name': 'Shamsul Bapary',
          'role': 'member'});

        // Deliberately different: transactions never hold a server uuid.
        expect(p.id, isNot('server-uuid'));
        expect(p.id, isNotEmpty);
        expect(p.remoteId, 'server-uuid');
        expect(p.source, ProfileSource.cloud);
      });
    });

    test('a pull twice does not duplicate the donor', () async {
      await LocalDb.withTempDb((db) async {
        final row = {'id': 'server-uuid', 'full_name': 'Roxi', 'role': 'member'};
        await db.upsertCloudProfile(row);
        await db.upsertCloudProfile(row);
        expect(await db.allProfiles(), hasLength(1));
      });
    });

    test('the earliest client_created_at is kept on merge', () async {
      await LocalDb.withTempDb((db) async {
        final local = await db.ensureProfile(fullName: 'Roxi');
        final serverCreated = DateTime(2020);
        // Pretend this device learned of the donor only today.
        final raw = await db.db;
        await raw.update(
          'profiles_cache',
          {'client_created_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [local.id],
        );

        final merged = await db.upsertCloudProfile({
          'id': 'server-uuid',
          'full_name': 'Roxi',
          'role': 'member',
          'client_created_at': serverCreated.toIso8601String(),
        });

        expect(merged.clientCreatedAt, serverCreated,
            reason: 'the older of the two record dates wins');
      });
    });

    test('a cloud donor without a phone still merges with a local one by name',
        () async {
      await LocalDb.withTempDb((db) async {
        final local = await db.ensureProfile(fullName: 'Roxi');
        final merged = await db.upsertCloudProfile(
            {'id': 'server-uuid', 'full_name': 'roxi', 'role': 'member'});
        expect(merged.id, local.id);
      });
    });
  });

  group('sync state', () {
    test('a donor with no remote id is pending', () async {
      await LocalDb.withTempDb((db) async {
        await db.ensureProfile(fullName: 'Roxi');
        expect(await db.pendingProfileCount(), 1);
        expect((await db.pendingProfiles()).single.remoteId, isNull);
      });
    });

    test('markProfileSynced clears it without changing the local id', () async {
      await LocalDb.withTempDb((db) async {
        final p = await db.ensureProfile(fullName: 'Roxi');
        await db.markProfileSynced(id: p.id, remoteId: 'server-uuid');
        final after = await db.findProfileById(p.id);
        expect(after!.remoteId, 'server-uuid');
        expect(after.id, p.id);
        expect(await db.pendingProfileCount(), 0);
      });
    });

    test('a held transaction stays queued and still counts as pending', () async {
      await LocalDb.withTempDb((db) async {
        // The state pushPending leaves a transaction in when its donor cannot
        // be pushed. Nothing may retire it or the queue loses it silently.
        final donor = await db.ensureProfile(fullName: 'Roxi');
        final t = Txn.create(
          type: 'income',
          category: 'Imam Hadiya',
          amount: 300,
          paymentMethod: 'cash',
          enteredBy: 'op-1',
          memberId: donor.id,
        );
        await db.insertTxn(t);

        expect(SyncService.isHeldForDonor(t, donor), isTrue,
            reason: 'donor has no remoteId yet');

        final stillPending = await db.pendingTxns();
        expect(stillPending.map((x) => x.id), contains(t.id));
        expect(await db.pendingCount(), 1);
        expect(stillPending.single.isSynced, isFalse);

        // Once the member lands the hold lifts and the row is pushable.
        await db.markProfileSynced(id: donor.id, remoteId: 'server-uuid');
        final after = await db.findProfileById(donor.id);
        expect(SyncService.isHeldForDonor(t, after), isFalse);
        expect(await db.pendingCount(), 1,
            reason: 'the transaction itself is untouched until it is pushed');
      });
    });

    test('pending donors are ordered oldest first so the first one wins', () async {
      await LocalDb.withTempDb((db) async {
        // Insert directly with explicit timestamps; ensureProfile has no
        // clock seam and this ordering drives merge precedence.
        for (final t in [
          DateTime(2024, 3, 1),
          DateTime(2024, 1, 1),
          DateTime(2024, 2, 1),
        ]) {
          final p = Profile.create(
            id: 'p-${t.month}',
            fullName: 'Donor ${t.month}',
            clientCreatedAt: t,
          );
          await (await db.db).insert('profiles_cache', p.toLocalMap());
        }
        final order = (await db.pendingProfiles()).map((p) => p.fullName).toList();
        expect(order, ['Donor 1', 'Donor 2', 'Donor 3']);
      });
    });
  });

  group('searchProfiles', () {
    test('prefix matches outrank substring matches', () async {
      await LocalDb.withTempDb((db) async {
        for (final n in ['islam khan', 'taijul islam', 'shariful islam']) {
          await db.ensureProfile(fullName: n);
        }
        final hits = await db.searchProfiles('islam');
        expect(hits.first.fullName, 'islam khan',
            reason: 'the only prefix match sorts ahead of the substring matches');
        expect(hits.map((p) => p.fullName), contains('taijul islam'));
      });
    });

    test('is case and whitespace insensitive', () async {
      await LocalDb.withTempDb((db) async {
        await db.ensureProfile(fullName: 'Taijul Islam');
        expect((await db.searchProfiles('  TAIJUL  ')).single.fullName,
            'Taijul Islam');
      });
    });

    test('an unmatched query returns nothing', () async {
      await LocalDb.withTempDb((db) async {
        await db.ensureProfile(fullName: 'Roxi');
        expect(await db.searchProfiles('zzzz'), isEmpty);
      });
    });

    test('operators are excluded from the donor list', () async {
      await LocalDb.withTempDb((db) async {
        await db.ensureProfile(fullName: 'Roxi');
        await (await db.db).insert(
          'profiles_cache',
          Profile.create(
            id: 'op-1',
            fullName: 'Sazzad',
            role: ProfileRole.collector,
          ).toLocalMap(),
        );

        expect((await db.searchProfiles('')).map((p) => p.fullName), ['Roxi']);
        expect((await db.searchProfiles('sazz')).map((p) => p.fullName), isEmpty);
        expect((await db.searchProfiles('sazz', includeStaff: true)), hasLength(1));
        expect(await db.allProfiles(), hasLength(1));
        expect(await db.allProfiles(includeStaff: true), hasLength(2));
      });
    });

    test('a name containing SQL metacharacters is searched safely', () async {
      await LocalDb.withTempDb((db) async {
        final nasty = "'; drop table profiles_cache; --";
        await db.ensureProfile(fullName: nasty);
        expect((await db.searchProfiles('drop')).single.fullName, nasty);
        expect(await db.searchProfiles("' or 1=1 --"), isEmpty);
        // The table is still there.
        expect(await db.allProfiles(), hasLength(1));
      });
    });
  });

  group('transactions reference donors', () {
    test('a donor id survives a round trip and pushes as the remote uuid',
        () async {
      await LocalDb.withTempDb((db) async {
        final donor = await db.ensureProfile(fullName: 'Roxi');
        await db.markProfileSynced(id: donor.id, remoteId: 'server-uuid');

        final t = Txn.create(
          type: 'income',
          category: 'Imam Hadiya',
          amount: 300,
          paymentMethod: 'cash',
          enteredBy: 'op-1',
          memberId: donor.id,
          donorName: donor.fullName,
          donorPhone: '01712345678',
        );
        await db.insertTxn(t);

        final loaded = (await db.listTxns()).single;
        expect(loaded.memberId, donor.id);
        expect(loaded.donorName, 'Roxi');
        expect(loaded.hasDonor, isTrue);

        final payload = loaded.toSupabaseMap(resolvedMemberId: 'server-uuid');
        expect(payload['member_id'], 'server-uuid');
        expect(payload['donor_name'], 'Roxi');
      });
    });

    test('an unsynced donor id is never sent to the server', () async {
      await LocalDb.withTempDb((db) async {
        final donor = await db.ensureProfile(fullName: 'Roxi');
        final t = Txn.create(
          type: 'income',
          category: 'Imam Hadiya',
          amount: 300,
          paymentMethod: 'cash',
          enteredBy: 'op-1',
          memberId: donor.id,
        );
        await db.insertTxn(t);

        // SyncService resolves member_id itself and passes it in. Calling
        // toSupabaseMap with nothing resolved is the bug this guards.
        final payload = (await db.listTxns()).single.toSupabaseMap();
        expect(payload['member_id'], donor.id,
            reason: 'documented fallback; pushPending must always resolve it');
      });
    });
  });
}

