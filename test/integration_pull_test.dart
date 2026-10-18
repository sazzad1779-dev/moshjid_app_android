@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/local/local_db.dart';
import 'package:moshjid_app/data/sync/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Exercises the read path against the live Supabase project.
///
/// Read-only by design: it pulls the roster into a throwaway database and
/// asserts what the donor picker would show. Nothing is written to the server,
/// so it is safe to run, but it is tagged `integration` and skipped unless
/// explicitly asked for:
///
///   flutter test --tags integration --dart-define=RUN_INTEGRATION=true
///
/// It needs .env next to pubspec.yaml. Without it the test skips rather than
/// failing, so a fresh clone still runs the rest of the suite.
void main() {
  const runIt = bool.fromEnvironment('RUN_INTEGRATION');

  test('pulls the donor roster into the local cache', () async {
    final envFile = File('.env');
    if (!runIt || !envFile.existsSync()) {
      markTestSkipped('integration test not requested, or .env missing');
      return;
    }

    final env = <String, String>{};
    for (final line in envFile.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final i = t.indexOf('=');
      if (i > 0) env[t.substring(0, i)] = t.substring(i + 1).trim();
    }

    // Supabase builds a SharedPreferences-backed session store on
    // initialize, which has no platform channel under `flutter test`.
    SharedPreferences.setMockInitialValues({});

    await Supabase.initialize(
      url: env['SUPABASE_URL']!,
      publishableKey: env['SUPABASE_ANON_KEY']!,
    );

    // The device signs in as a collector; RLS then decides what it can read.
    await Supabase.instance.client.auth.signInWithPassword(
      email: env['SERVICE_EMAIL']!,
      password: env['SERVICE_PASSWORD']!,
    );

    final pulled = await LocalDb.withTempDb((db) async {
      final sync = SyncService(db, client: Supabase.instance.client);
      final count = await sync.pullProfiles();
      expect(count, isNotNull, reason: 'pull failed outright');
      expect(count, greaterThan(0), reason: 'device can see no donors at all');

      final donors = await db.allProfiles();
      expect(donors, isNotEmpty);
      // Every donor is stored with a server uuid, so none is left pending.
      expect(donors.every((p) => p.remoteId != null), isTrue);
      expect(donors.every((p) => !p.isPending), isTrue);
      // Local ids are the device's own, never the server's.
      expect(donors.every((p) => p.id != p.remoteId), isTrue);

      // The picker filters to members, so an operator must not leak in.
      final byName = await db.searchProfiles('sazzad');
      expect(
        byName.where((p) => p.fullName.toLowerCase().contains('sazzad')),
        isEmpty,
        reason: 'collectors are not donors',
      );

      // A real donor must be findable by prefix.
      final hit = await db.searchProfiles('taij');
      expect(hit.map((p) => p.fullName), contains('Taijul Islam'));

      return donors.length;
    });

    // ignore: avoid_print
    print('donors cached: $pulled');
  });

  test('a second pull does not duplicate anyone', () async {
    final envFile = File('.env');
    if (!runIt || !envFile.existsSync()) {
      markTestSkipped('integration test not requested, or .env missing');
      return;
    }
    final env = <String, String>{};
    for (final line in envFile.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final i = t.indexOf('=');
      if (i > 0) env[t.substring(0, i)] = t.substring(i + 1).trim();
    }
    // Supabase builds a SharedPreferences-backed session store on
    // initialize, which has no platform channel under `flutter test`.
    SharedPreferences.setMockInitialValues({});

    await Supabase.initialize(
      url: env['SUPABASE_URL']!,
      publishableKey: env['SUPABASE_ANON_KEY']!,
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: env['SERVICE_EMAIL']!,
      password: env['SERVICE_PASSWORD']!,
    );

    await LocalDb.withTempDb((db) async {
      final sync = SyncService(db, client: Supabase.instance.client);
      expect(await sync.pullProfiles(), isNotNull);
      final first = (await db.allProfiles()).length;
      expect(first, greaterThan(0));
      await sync.pullProfiles();
      await sync.pullProfiles();
      expect((await db.allProfiles()).length, first,
          reason: 'repeat pulls must be idempotent');
    });
  });
}