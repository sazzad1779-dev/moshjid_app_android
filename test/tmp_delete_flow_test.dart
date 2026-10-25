import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/models/txn.dart';
import 'package:moshjid_app/data/sync/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('member delete and txn delete push is_deleted', () async {
    final requests = <String>[];
    const headers = {'content-type': 'application/json; charset=utf-8'};
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((request) async {
        requests.add('${request.method} ${request.url} BODY=${request.body}');
        if (request.method == 'GET') {
          return http.Response(jsonEncode(const []), 200,
              request: request, headers: headers);
        }
        return http.Response('', 201, request: request, headers: headers);
      }),
    );
    try {
      await LocalDb.withTempDb((db) async {
        final p = await db.ensureProfile(fullName: 'Roxi');
        await db.markProfileSynced(id: p.id, remoteId: 'server-1');
        final t = Txn.create(
          type: 'income',
          category: 'Imam Hadiya',
          amount: 100,
          paymentMethod: 'cash',
          enteredBy: 'op',
          memberId: p.id,
        );
        await db.insertTxn(t);
        await db.markSynced(t.id, DateTime.now());

        await db.softDeleteProfile(p.id);
        await db.softDelete(t.id);
        final sync = SyncService(db, client: client);
        await sync.pushProfiles();
        await sync.pushPending();
      });
    } finally {
      await client.dispose();
    }
    // ignore: avoid_print
    print(requests.join('\n'));
  });
}
