import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:alarm_example/screens/home.dart';
import 'package:alarm_example/utils/logging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  setupLogging(showDebugLogs: true);

  // Subscribed before Alarm.init() on purpose. A snooze taken while the app was
  // not running is replayed during init, and Alarm.snoozed is a plain broadcast
  // stream, so a listener registered afterwards -- from a widget, say -- would
  // miss it entirely.
  final replayedSnoozes = <({int id, DateTime nextRingAt})>[];
  final snoozeSubscription = Alarm.snoozed.listen(replayedSnoozes.add);

  await Alarm.init();

  for (final snooze in replayedSnoozes) {
    debugPrint('Replayed snooze: alarm ${snooze.id} rings at '
        '${snooze.nextRingAt}');
  }
  await snoozeSubscription.cancel();

  runApp(
    MaterialApp(
      theme: ThemeData(useMaterial3: false),
      home: const ExampleAlarmHomeScreen(),
    ),
  );
}
