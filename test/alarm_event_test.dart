import 'package:alarm/alarm.dart';
import 'package:alarm/service/alarm_storage.dart';
import 'package:alarm/src/alarm_trigger_api_impl.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_host.dart';

/// The host event mechanism, beyond the snooze case that already exercises it.
///
/// `moved` is covered in depth by the snooze suite, since a snooze *is* a move.
/// What is untested there is the other verb and the other causes, which nothing
/// in the plugin emits yet — so these tests stand in for the callers that will,
/// and are the reason a later change can rely on this plumbing working.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHost host;

  AlarmSettings buildAlarm(int id, DateTime dateTime) => AlarmSettings(
        id: id,
        dateTime: dateTime,
        volumeSettings: const VolumeSettings.fixed(),
        notificationSettings: const NotificationSettings(
          title: 'Wake up',
          body: '',
        ),
      );

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Alarm.resetForTesting();
    AlarmStorage.resetForTesting();
    AlarmTriggerApiImpl.resetForTesting();
    host = FakeHost()..install();
  });

  tearDown(() {
    host.remove();
    Alarm.resetForTesting();
    AlarmStorage.resetForTesting();
    AlarmTriggerApiImpl.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
  });

  group('a dropped alarm', () {
    test('is removed, reported, and acknowledged on init', () async {
      final scheduledFor = DateTime.now().subtract(const Duration(hours: 2));
      await AlarmStorage.saveAlarm(buildAlarm(42, scheduledFor));
      host.pending.add(droppedEvent(42, scheduledFor));

      final seen = <AlarmEvent>[];
      final subscription = Alarm.events.listen(seen.add);
      addTearDown(subscription.cancel);

      await Alarm.init();

      expect(await Alarm.getAlarms(), isEmpty);
      expect(Alarm.scheduled.value.alarms, isEmpty);
      expect(
        host.acknowledged,
        contains((42, scheduledFor.millisecondsSinceEpoch)),
      );

      expect(seen, hasLength(1));
      final event = seen.single;
      expect(event, isA<AlarmDropped>());
      expect(event.id, 42);
      expect(event.cause, AlarmEventCause.staleAtBoot);
      expect(
        (event as AlarmDropped).scheduledFor.millisecondsSinceEpoch,
        scheduledFor.millisecondsSinceEpoch,
      );
    });

    test('is not stopped again by the reconcile loop', () async {
      // The host already discarded it, so telling the host to stop it would be
      // a pointless round trip that also reports a stop for an alarm the app
      // was never told was ringing.
      final scheduledFor = DateTime.now().subtract(const Duration(hours: 2));
      await AlarmStorage.saveAlarm(buildAlarm(42, scheduledFor));
      host.pending.add(droppedEvent(42, scheduledFor));

      await Alarm.init();

      expect(host.calls, isNot(contains('stopAlarm')));
    });

    test('does not reach the snoozed stream', () async {
      final scheduledFor = DateTime.now().subtract(const Duration(hours: 2));
      await AlarmStorage.saveAlarm(buildAlarm(42, scheduledFor));
      host.pending.add(droppedEvent(42, scheduledFor));

      final snoozes = <({int id, DateTime nextRingAt})>[];
      final subscription = Alarm.snoozed.listen(snoozes.add);
      addTearDown(subscription.cancel);

      await Alarm.init();

      expect(snoozes, isEmpty);
    });

    test('applies when the host reports it live', () async {
      final scheduledFor = DateTime.now().subtract(const Duration(hours: 2));
      await AlarmStorage.saveAlarm(buildAlarm(7, scheduledFor));
      await Alarm.init();

      final seen = <AlarmEvent>[];
      final subscription = Alarm.events.listen(seen.add);
      addTearDown(subscription.cancel);

      await hostReportsEvent(droppedEvent(7, scheduledFor));

      expect(await Alarm.getAlarm(7), isNull);
      expect(seen.single, isA<AlarmDropped>());
    });
  });

  group('a move the platform forced', () {
    test('reaches events but not the snoozed stream', () async {
      // Alarm.snoozed means the user deferred the alarm. A deferral the
      // platform imposed is not that, and reporting it there would put an
      // event in the app's records that the app cannot explain.
      final nextRingAt = DateTime.now().add(const Duration(seconds: 30));
      await AlarmStorage.saveAlarm(
        buildAlarm(9, DateTime.now().subtract(const Duration(seconds: 5))),
      );
      host.pending.add(refusedRingEvent(9, nextRingAt));

      final seen = <AlarmEvent>[];
      final snoozes = <({int id, DateTime nextRingAt})>[];
      final events = Alarm.events.listen(seen.add);
      final snoozed = Alarm.snoozed.listen(snoozes.add);
      addTearDown(events.cancel);
      addTearDown(snoozed.cancel);

      await Alarm.init();

      expect(snoozes, isEmpty, reason: 'the user did not snooze this');
      expect(seen.single, isA<AlarmMoved>());
      expect(seen.single.cause, AlarmEventCause.platformRefusal);

      final stored = await Alarm.getAlarm(9);
      expect(stored, isNotNull);
      expect(
        stored!.dateTime.millisecondsSinceEpoch,
        nextRingAt.millisecondsSinceEpoch,
        reason: 'the shifted time must reach Dart storage, or the next '
            'reconciliation stops the alarm and cancels the retry',
      );
    });
  });
}
