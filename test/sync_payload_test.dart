import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/models/profile.dart';
import 'package:moshjid_app/data/models/txn.dart';
import 'package:moshjid_app/data/sync/sync_service.dart';

/// Covers the parts of sync that can be checked without a server. The network
/// paths are exercised manually via the in-app connection diagnostic.
void main() {
  Txn txnWith({String? memberId, String? donorName, String? donorPhone}) =>
      Txn.create(
        type: 'income',
        category: 'Imam Hadiya',
        amount: 300,
        paymentMethod: 'cash',
        enteredBy: 'op-1',
        memberId: memberId,
        donorName: donorName,
        donorPhone: donorPhone,
      );

  Profile donor({
    String id = 'local-uuid',
    String? remoteId,
    String fullName = 'Roxi',
    String? phone = '01712345678',
    DateTime? createdAt,
  }) =>
      Profile(
        id: id,
        remoteId: remoteId,
        fullName: fullName,
        phone: phone,
        clientCreatedAt: createdAt ?? DateTime(2024, 6, 1),
        syncedAt: remoteId == null ? null : DateTime(2024, 6, 2),
      );

  group('buildPayload: member_id', () {
    test('sends the donor server uuid, never the local id', () {
      final t = txnWith(memberId: 'local-uuid');
      final payload =
          SyncService.buildPayload(t, donor: donor(remoteId: 'server-uuid'));
      expect(payload['member_id'], 'server-uuid');
    });

    test('omits member_id when the donor has not reached the server', () {
      // The failure mode this prevents is worse than a missing link: this is
      // an upsert, so sending null would erase the server's own value.
      final t = txnWith(memberId: 'local-uuid');
      final payload = SyncService.buildPayload(t, donor: donor());
      expect(payload.containsKey('member_id'), isFalse);
    });

    test('omits member_id when the donor cannot be found at all', () {
      final t = txnWith(memberId: 'vanished');
      final payload = SyncService.buildPayload(t);
      expect(payload.containsKey('member_id'), isFalse);
    });

    test('omits member_id for a transaction with no donor', () {
      final payload = SyncService.buildPayload(txnWith());
      expect(payload.containsKey('member_id'), isFalse);
    });

    test('never sends the local id, even in the unresolved case', () {
      final t = txnWith(memberId: 'local-uuid');
      final payload = SyncService.buildPayload(t, donor: donor());
      expect(payload.values, isNot(contains('local-uuid')));
    });
  });

  group('buildPayload: donor details', () {
    test('uses the donor record spelling, not the typed text', () {
      final t = txnWith(
        memberId: 'local-uuid',
        donorName: 'roxi bapary',
        donorPhone: '01712-345678',
      );
      final payload = SyncService.buildPayload(
        t,
        donor: donor(
          fullName: 'Roxi Bapary',
          phone: '+8801712345678',
          remoteId: 'server-uuid',
        ),
      );
      expect(payload['donor_name'], 'Roxi Bapary');
      expect(payload['donor_phone'], '+8801712345678');
    });

    test('keeps the phone exactly as the donor holds it', () {
      // donor_phone is display data, not an identity key, so it is never
      // normalized. NameKey.phoneKey is for match_key alone.
      final payload = SyncService.buildPayload(
        txnWith(memberId: 'l'),
        donor: donor(remoteId: 's', phone: '+880 1712-345678'),
      );
      expect(payload['donor_phone'], '+880 1712-345678');
    });

    test('a donor with no phone sends null rather than the key being dropped', () {
      final payload = SyncService.buildPayload(
        txnWith(memberId: 'l'),
        donor: donor(remoteId: 's', phone: null),
      );
      expect(payload.containsKey('donor_phone'), isTrue);
      expect(payload['donor_phone'], isNull);
    });
  });

  group('buildPayload: other fields', () {
    test('still excludes type, which the server derives from category_id', () {
      final payload = SyncService.buildPayload(txnWith(memberId: 'l'));
      expect(payload.containsKey('type'), isFalse);
    });

    test('prefers the resolved category id', () {
      final t = Txn.create(
        type: 'income',
        category: 'Imam Hadiya',
        categoryId: 'stale',
        amount: 100,
        paymentMethod: 'cash',
        enteredBy: 'op-1',
      );
      expect(SyncService.buildPayload(t, categoryId: 'fresh')['category_id'],
          'fresh');
      expect(SyncService.buildPayload(t)['category_id'], 'stale');
    });

    test('a soft-deleted row still upserts as deleted', () {
      final t = Txn.fromLocalMap({
        ...txnWith(memberId: 'l').toLocalMap(),
        'is_deleted': 1,
      });
      expect(SyncService.buildPayload(t, donor: donor(remoteId: 's'))['is_deleted'],
          isTrue);
    });
  });

  group('isHeldForDonor: members before transactions', () {
    test('holds a transaction whose donor is not on the server yet', () {
      expect(SyncService.isHeldForDonor(txnWith(memberId: 'local-uuid'),
          donor(remoteId: null)),
          isTrue);
    });

    test('lets a transaction through once the donor has a uuid', () {
      expect(
          SyncService.isHeldForDonor(txnWith(memberId: 'local-uuid'),
              donor(remoteId: 'server-uuid')),
          isFalse);
    });

    test('does not hold when the donor cannot be resolved at all', () {
      // Nothing to wait for: pruneCloudProfiles never deletes a pending row, so
      // a null donor means a bad local id and pushing beats stalling forever.
      expect(SyncService.isHeldForDonor(txnWith(memberId: 'gone'), null),
          isFalse);
    });

    test('does not hold a transaction with no member', () {
      expect(SyncService.isHeldForDonor(txnWith(), donor(remoteId: null)),
          isFalse);
    });
  });

  group('free-text donors', () {
    test('a typed name rides along with no member link', () {
      final t = txnWith(memberId: null, donorName: 'Walk-in Donor');
      final payload = SyncService.buildPayload(t, donor: null);

      expect(payload['donor_name'], 'Walk-in Donor');
      // No profile was linked, so the key must be absent rather than null --
      // this is an upsert, and a null would wipe a value the server already has.
      expect(payload.containsKey('member_id'), isFalse);
    });

    test('a typed donor is never held waiting for a member to sync', () {
      // This is the whole point of free text: it must not block on the member
      // push, or an unnamed cash payment could never be recorded online.
      final t = txnWith(memberId: null, donorName: 'Walk-in Donor');
      expect(SyncService.isHeldForDonor(t, null), isFalse);
      expect(t.hasDonor, isTrue, reason: 'a name alone still counts as a donor');
    });

    test('an empty typed name is not a donor at all', () {
      final t = txnWith(memberId: null, donorName: '   ');
      expect(SyncService.isHeldForDonor(t, null), isFalse);
    });

    test('a linked member still wins over anything typed', () {
      final t = txnWith(memberId: 'local-uuid', donorName: 'Roxi');
      final payload = SyncService.buildPayload(t, donor: donor(remoteId: 'srv'));
      expect(payload['member_id'], 'srv');
      expect(payload['donor_name'], 'Roxi');
    });
  });

  group('member edit and delete payloads', () {
    test('an edit does not restamp created_at on the server row', () {
      // created_at drives "keep the first" precedence in both the trigger and
      // the duplicate merge. Rewriting it on an edit would reorder who wins.
      final edited = donor(remoteId: 'server-uuid')
          .applyEdit(fullName: 'Roxi Ahmed', phone: '01712345678');
      final payload = edited.toSupabaseMap();
      expect(payload.containsKey('created_at'), isFalse);
      expect(payload['updated_at'], isNotNull);
    });

    test('a new donor sends created_at because the row does not exist yet', () {
      final payload = donor(remoteId: null).toSupabaseMap();
      expect(payload['created_at'], isNotNull);
    });

    test('a delete sends is_deleted rather than removing the row', () {
      final payload =
          donor(remoteId: 'server-uuid').asDeleted.toSupabaseMap();
      expect(payload['is_deleted'], isTrue);
      // The id stays: the row is retained so transactions keep resolving.
      expect(payload['id'], 'server-uuid');
    });

    test('an edit preserves the local id and the server uuid', () {
      final edited = donor(remoteId: 'server-uuid').applyEdit(fullName: 'New');
      expect(edited.id, 'local-uuid');
      expect(edited.remoteId, 'server-uuid');
      expect(edited.pushId, 'server-uuid',
          reason: 'an edit must update the existing row, not insert a new one');
    });

    test('an edit clears the deleted flag so re-adding brings them back', () {
      final revived = donor(remoteId: 'server-uuid').asDeleted
          .applyEdit(fullName: 'Roxi');
      expect(revived.isDeleted, isFalse);
      expect(revived.syncedAt, isNull, reason: 'and is re-queued for upload');
    });
  });

  group('SyncResult', () {
    test('is quiet only when nothing happened and nothing failed', () {
      expect(const SyncResult().isQuiet, isTrue);
      expect(const SyncResult(pushed: 1).isQuiet, isFalse);
      expect(const SyncResult(pushedProfiles: 1).isQuiet, isFalse);
      expect(const SyncResult(mergedProfiles: 1).isQuiet, isFalse);
      expect(const SyncResult(pulledProfiles: 5).isQuiet, isFalse);
      expect(const SyncResult(error: 'offline').isQuiet, isFalse);
    });

    test('deferred transactions stay quiet so the timer does not nag', () {
      // A member that cannot push holds its transactions every cycle. That is
      // not newsworthy; the pending badge already reports the backlog.
      expect(const SyncResult(deferred: 3).isQuiet, isTrue);
    });
  });
}