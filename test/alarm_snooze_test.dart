import 'package:alarm/alarm.dart';
import 'package:alarm/service/alarm_storage.dart';
import 'package:alarm/src/alarm_trigger_api_impl.dart';
import 'package:alarm/src/generated/platform_bindings.g.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the Android host over the real pigeon channels.
///
/// The snooze contract is a negotiation between Dart and the host — the host
/// records a marker, Dart applies it, the host drops it once Dart confirms —
/// so the interesting behaviour only shows up when both halves are present.
/// Recording every call lets a test assert what Dart did *not* do, which is
/// what the B1 regression is about.
class _FakeHost {
  _FakeHost();

  final List<String> calls = <String>[];
  final List<PendingSnoozeWire> pending = <PendingSnoozeWire>[];
  final List<(int, int)> acknowledged = <(int, int)>[];
  final Set<int> ringing = <int>{};

  static const _prefix = 'dev.flutter.pigeon.alarm.AlarmApi.';

  void install() {
    _handle('getPendingSnoozes', (_) => <Object?>[pending.toList()]);
    _handle('acknowledgeSnooze', (args) {
      acknowledged.add((args![0]! as int, args[1]! as int));
      return <Object?>[null];
    });
    _handle('setAlarm', (_) => <Object?>[null]);
    _handle('stopAlarm', (_) => <Object?>[null]);
    _handle('stopAll', (_) => <Object?>[null]);
    _handle('isRinging', (args) {
      final id = args?[0] as int?;
      final result = id == null ? ringing.isNotEmpty : ringing.contains(id);
      return <Object?>[result];
    });
    _handle('setWarningNotificationOnKill', (_) => <Object?>[null]);
    _handle('disableWarningNotificationOnKill', (_) => <Object?>[null]);
  }

  void _handle(String name, Object? Function(List<Object?>? args) respond) {
    final channel = BasicMessageChannel<Object?>(
      '$_prefix$name',
      AlarmApi.pigeonChannelCodec,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(channel, (message) async {
      calls.add(name);
      return respond(message as List<Object?>?);
    });
  }

  void remove() {
    for (final name in const [
      'getPendingSnoozes',
      'acknowledgeSnooze',
      'setAlarm',
      'stopAlarm',
      'stopAll',
      'isRinging',
      'setWarningNotificationOnKill',
      'disableWarningNotificationOnKill',
    ]) {
      final channel = BasicMessageChannel<Object?>(
        '$_prefix$name',
        AlarmApi.pigeonChannelCodec,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(channel, null);
    }
  }
}

/// Lets already-queued microtasks run.
///
/// `Alarm.snoozed` is a broadcast stream, so a listener is notified in a
/// microtask rather than synchronously with the `add`.
Future<void> pump() => Future<void>.delayed(Duration.zero);

/// Delivers an `alarmSnoozed` call the way the host would, and completes only
/// when Dart has finished handling it.
Future<void> hostReportsSnooze(int alarmId, DateTime nextRingAt) async {
  const channelName = 'dev.flutter.pigeon.alarm.AlarmTriggerApi.alarmSnoozed';
  final encoded = AlarmTriggerApi.pigeonChannelCodec.encodeMessage(
    <Object?>[alarmId, nextRingAt.millisecondsSinceEpoch],
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channelName, encoded, (_) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHost host;

  AlarmSettings buildAlarm(
    int id,
    DateTime dateTime, {
    Duration? snoozeDuration = const Duration(minutes: 9),
  }) {
    return AlarmSettings(
      id: id,
      dateTime: dateTime,
      volumeSettings: const VolumeSettings.fixed(),
      androidSnoozeDuration: snoozeDuration,
      notificationSettings: const NotificationSettings(
        title: 'Wake up',
        body: '',
        androidSnoozeButton: 'Snooze',
      ),
    );
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Alarm.resetForTesting();
    AlarmStorage.resetForTesting();
    AlarmTriggerApiImpl.resetForTesting();
    host = _FakeHost()..install();
  });

  tearDown(() {
    host.remove();
    Alarm.resetForTesting();
    AlarmStorage.resetForTesting();
    AlarmTriggerApiImpl.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
  });

  group('snooze reconciliation on init', () {
    test(
      'B1: reopening before the snooze fires does not cancel it',
      () async {
        // The alarm rang at its original time and the user snoozed from the
        // notification with no engine running, so Dart still has the original
        // past time. Reopening the app must not read that as a missed alarm.
        final originalTime =
            DateTime.now().subtract(const Duration(minutes: 2));
        final nextRingAt = DateTime.now().add(const Duration(minutes: 7));
        await AlarmStorage.saveAlarm(buildAlarm(42, originalTime));
        host.pending.add(
          PendingSnoozeWire(
            alarmId: 42,
            millisecondsSinceEpoch: nextRingAt.millisecondsSinceEpoch,
          ),
        );

        await Alarm.init();

        expect(
          host.calls,
          isNot(contains('stopAlarm')),
          reason: 'the snoozed alarm must not be stopped as if it were missed',
        );

        final stored = await Alarm.getAlarm(42);
        expect(stored, isNotNull);
        expect(
          stored!.dateTime.millisecondsSinceEpoch,
          nextRingAt.millisecondsSinceEpoch,
          reason: 'Dart storage must hold the shifted time, not the original',
        );
      },
    );

    test('B2: a marker recorded with no engine is applied on the next init',
        () async {
      final nextRingAt = DateTime.now().add(const Duration(minutes: 9));
      await AlarmStorage.saveAlarm(
        buildAlarm(7, DateTime.now().subtract(const Duration(minutes: 1))),
      );
      host.pending.add(
        PendingSnoozeWire(
          alarmId: 7,
          millisecondsSinceEpoch: nextRingAt.millisecondsSinceEpoch,
        ),
      );

      await Alarm.init();

      expect(Alarm.scheduled.value.containsId(7), isTrue);
      expect(Alarm.ringing.value.containsId(7), isFalse);
    });

    test('acknowledges the marker it applied, matching id and timestamp',
        () async {
      final nextRingAt = DateTime.now().add(const Duration(minutes: 5));
      await AlarmStorage.saveAlarm(
        buildAlarm(3, DateTime.now().subtract(const Duration(minutes: 1))),
      );
      host.pending.add(
        PendingSnoozeWire(
          alarmId: 3,
          millisecondsSinceEpoch: nextRingAt.millisecondsSinceEpoch,
        ),
      );

      await Alarm.init();

      expect(
        host.acknowledged,
        contains((3, nextRingAt.millisecondsSinceEpoch)),
      );
    });

    test('a marker whose time has already passed is refused, not applied',
        () async {
      // Applying it would rewrite the alarm to a past time, which the
      // reconciliation loop then deletes.
      final original = DateTime.now().subtract(const Duration(minutes: 30));
      final stalePending = DateTime.now().subtract(const Duration(minutes: 10));
      await AlarmStorage.saveAlarm(buildAlarm(11, original));
      host.pending.add(
        PendingSnoozeWire(
          alarmId: 11,
          millisecondsSinceEpoch: stalePending.millisecondsSinceEpoch,
        ),
      );

      await Alarm.init();

      expect(Alarm.scheduled.value.containsId(11), isFalse);
    });

    test('rebuilds state for a marker that was already applied', () async {
      // The crash window: Dart persisted the shifted time, then the process
      // died before native could acknowledge. The marker survives and storage
      // already agrees with it, so there is nothing to write — but a fresh
      // isolate still has to surface the alarm.
      final nextRingAt = DateTime.now().add(const Duration(minutes: 7));
      await AlarmStorage.saveAlarm(buildAlarm(99, nextRingAt));
      host.pending.add(
        PendingSnoozeWire(
          alarmId: 99,
          millisecondsSinceEpoch: nextRingAt.millisecondsSinceEpoch,
        ),
      );

      await Alarm.init();

      expect(
        Alarm.scheduled.value.containsId(99),
        isTrue,
        reason: 'an already-applied marker must not leave the alarm invisible',
      );
    });

    test('an alarm genuinely missed is still stopped', () async {
      // Guards the B1 fix against over-correcting: with no marker, a past
      // alarm that is not ringing should still be cleaned up.
      await AlarmStorage.saveAlarm(
        buildAlarm(5, DateTime.now().subtract(const Duration(hours: 1))),
      );

      await Alarm.init();

      expect(host.calls, contains('stopAlarm'));
    });
  });

  group('live snooze report', () {
    test('moves the alarm forward and emits on Alarm.snoozed', () async {
      final nextRingAt = DateTime.now().add(const Duration(minutes: 9));
      await AlarmStorage.saveAlarm(
        buildAlarm(21, DateTime.now().add(const Duration(minutes: 1))),
      );
      await Alarm.init();

      final events = <({int id, DateTime nextRingAt})>[];
      final sub = Alarm.snoozed.listen(events.add);
      addTearDown(sub.cancel);

      await hostReportsSnooze(21, nextRingAt);
      await pump();

      expect(events, hasLength(1));
      expect(events.single.id, 21);
      final stored = await Alarm.getAlarm(21);
      expect(
        stored!.dateTime.millisecondsSinceEpoch,
        nextRingAt.millisecondsSinceEpoch,
      );
    });

    test('applying the same deferral twice changes nothing', () async {
      final nextRingAt = DateTime.now().add(const Duration(minutes: 9));
      await AlarmStorage.saveAlarm(
        buildAlarm(22, DateTime.now().add(const Duration(minutes: 1))),
      );
      await Alarm.init();

      final events = <({int id, DateTime nextRingAt})>[];
      final sub = Alarm.snoozed.listen(events.add);
      addTearDown(sub.cancel);

      await hostReportsSnooze(22, nextRingAt);
      await pump();
      await hostReportsSnooze(22, nextRingAt);
      await pump();

      expect(
        events,
        hasLength(1),
        reason: 'a replayed marker must collapse into the live report',
      );
      final stored = await Alarm.getAlarm(22);
      expect(
        stored!.dateTime.millisecondsSinceEpoch,
        nextRingAt.millisecondsSinceEpoch,
      );
    });

    test('an older deferral cannot pull a newer one backwards', () async {
      final earlier = DateTime.now().add(const Duration(minutes: 5));
      final later = DateTime.now().add(const Duration(minutes: 15));
      await AlarmStorage.saveAlarm(
        buildAlarm(23, DateTime.now().add(const Duration(minutes: 1))),
      );
      await Alarm.init();

      await hostReportsSnooze(23, later);
      await hostReportsSnooze(23, earlier);

      final stored = await Alarm.getAlarm(23);
      expect(
        stored!.dateTime.millisecondsSinceEpoch,
        later.millisecondsSinceEpoch,
      );
    });

    test('the reply to the host waits for Dart to persist', () async {
      // The host drops its marker on the strength of this reply, so replying
      // before the write lands would lose the deferral to a crash in between.
      final nextRingAt = DateTime.now().add(const Duration(minutes: 9));
      await AlarmStorage.saveAlarm(
        buildAlarm(31, DateTime.now().add(const Duration(minutes: 1))),
      );
      await Alarm.init();

      await hostReportsSnooze(31, nextRingAt);

      // handlePlatformMessage completes only once the handler's future does,
      // so by here the write must already be visible.
      final stored = await Alarm.getAlarm(31);
      expect(
        stored!.dateTime.millisecondsSinceEpoch,
        nextRingAt.millisecondsSinceEpoch,
      );
    });
  });
}
