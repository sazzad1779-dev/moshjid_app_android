import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moshjid_app/data/auth/auth_service.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/sync/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Exercises the pull side of sync with a fake PostgREST endpoint, so the
/// merge rules can be checked without a live project.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> serverRow({
    String id = 'server-1',
    String fullName = 'Roxi',
    String? phone,
    bool isDeleted = false,
  }) => {
    'id': id,
    'full_name': fullName,
    'phone': phone,
    'role': 'member',
    'status': 'active',
    'is_monthly': true,
    'is_deleted': isDeleted,
    'client_created_at': DateTime(2024, 1, 1).toIso8601String(),
    'created_at': DateTime(2024, 1, 1).toIso8601String(),
  };

  /// A client whose `profiles` read returns [profiles]; every other table
  /// returns an empty list.
  SupabaseClient fakeClient(List<Map<String, dynamic>> profiles) {
    const headers = {'content-type': 'application/json; charset=utf-8'};
    return SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((request) async {
        final body = request.url.path == '/rest/v1/profiles'
            ? profiles
            : const <Object>[];
        return http.Response(
          jsonEncode(body),
          200,
          request: request,
          headers: headers,
        );
      }),
    );
  }

  group('pullProfiles', () {
    test('a server rename lands on the row matched by remote id', () async {
      final client = fakeClient([
        serverRow(fullName: 'Roxi Ahmed', phone: '01712345678'),
      ]);
      try {
        await LocalDb.withTempDb((db) async {
          final local = await db.ensureProfile(fullName: 'Roxi');
          await db.markProfileSynced(id: local.id, remoteId: 'server-1');

          final sync = _TestSync(db, client: client);
          expect(await sync.pullProfiles(), 1);

          final after = (await db.findProfileById(local.id))!;
          expect(after.fullName, 'Roxi Ahmed');
          expect(after.phone, '01712345678');
          expect(after.remoteId, 'server-1');
          expect(after.isPending, isFalse);
          expect(
            await db.allProfiles(),
            hasLength(1),
            reason: 'the changed identity must update the row, not add one',
          );
        });
      } finally {
        await client.dispose();
      }
    });

    test('a server-side phone change follows the same row', () async {
      final client = fakeClient([serverRow(phone: '01799999999')]);
      try {
        await LocalDb.withTempDb((db) async {
          final local = await db.ensureProfile(fullName: 'Roxi');
          await db.markProfileSynced(id: local.id, remoteId: 'server-1');

          await _TestSync(db, client: client).pullProfiles();

          final after = (await db.findProfileById(local.id))!;
          expect(after.phone, '01799999999');
          expect(await db.allProfiles(), hasLength(1));
        });
      } finally {
        await client.dispose();
      }
    });

    test('an empty server roster prunes cached cloud members', () async {
      final client = fakeClient([]);
      try {
        await LocalDb.withTempDb((db) async {
          await db.upsertCloudProfile(serverRow());
          expect(await db.allProfiles(), hasLength(1));

          final pulled = await _TestSync(db, client: client).pullProfiles();

          expect(pulled, 0);
          expect(
            await db.allProfiles(),
            isEmpty,
            reason: 'nothing carries a server uuid any more',
          );
        });
      } finally {
        await client.dispose();
      }
    });

    test('an empty server roster leaves pending local members alone', () async {
      final client = fakeClient([]);
      try {
        await LocalDb.withTempDb((db) async {
          final pending = await db.ensureProfile(fullName: 'Locally Added');

          await _TestSync(db, client: client).pullProfiles();

          expect(await db.findProfileById(pending.id), isNotNull);
          expect((await db.pendingProfiles()).single.id, pending.id);
        });
      } finally {
        await client.dispose();
      }
    });

    test(
      'a pull does not overwrite an edit that has not been pushed',
      () async {
        final client = fakeClient([serverRow()]);
        try {
          await LocalDb.withTempDb((db) async {
            final local = await db.ensureProfile(fullName: 'Roxi');
            await db.markProfileSynced(id: local.id, remoteId: 'server-1');
            expect(
              await db.updateProfile(id: local.id, fullName: 'Roxi Ahmed'),
              isNull,
            );

            await _TestSync(db, client: client).pullProfiles();

            final after = (await db.findProfileById(local.id))!;
            expect(
              after.fullName,
              'Roxi Ahmed',
              reason: 'the local edit still owns the row until it is pushed',
            );
            expect(after.isPending, isTrue);
          });
        } finally {
          await client.dispose();
        }
      },
    );
  });

  group('sync', () {
    test('re-resolves the current user entry on every run', () async {
      final client = fakeClient([]);
      try {
        await LocalDb.withTempDb((db) async {
          final auth = _FakeAuth();
          final sync = _TestSync(db, client: client, auth: auth);

          await sync.sync();
          await sync.sync();

          expect(auth.refreshes, 2);
          expect(auth.forced, [
            true,
            true,
          ], reason: 'a cached id must be bypassed every sync');
        });
      } finally {
        await client.dispose();
      }
    });
  });
}

/// SyncService with the connectivity probe replaced, so tests never touch the
/// platform channel. The pull path itself runs unchanged.
class _TestSync extends SyncService {
  _TestSync(super.local, {super.client, super.auth});

  @override
  Future<bool> get isOnline async => true;
}

class _FakeAuth extends AuthService {
  int refreshes = 0;
  final forced = <bool>[];

  @override
  Future<bool> ensureSignedIn() async => true;

  @override
  Future<String> resolveEnteredById({bool forceRefresh = false}) async {
    refreshes++;
    forced.add(forceRefresh);
    return 'profile-id';
  }
}
