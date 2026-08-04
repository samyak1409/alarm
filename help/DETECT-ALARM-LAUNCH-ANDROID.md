# Telling an alarm launch from a manual one (Android)

When a full screen intent fires, the plugin opens your launcher activity. That
intent is identical to the one you get from tapping the app icon — same action,
same category, no extras — so from inside the app "an alarm opened us" and "the
user opened us" look the same.

`Alarm.ringing` tells you *which* alarm is ringing, but not *who* opened the app.
An app that wants to step back out of the way once the alarm is stopped, rather
than sit on top of whatever the user was doing, needs the difference.

## The RING activity doesn't have to be a dedicated one

[Presenting the alarm on your own screen](https://github.com/gdelataillade/alarm/blob/main/README.md#presenting-the-alarm-on-your-own-screen)
covers declaring an activity that handles `com.gdelataillade.alarm.action.RING`,
which receives the alarm extras. That activity does not have to be a separate
one. If you don't want a separate alarm screen, but still need to know that an
alarm is what opened your app, declare the filter on your existing
`MainActivity` alongside the launcher filter:

```xml
<activity
    android:name=".MainActivity"
    android:launchMode="singleTop"
    ...>
    <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
    </intent-filter>
    <intent-filter>
        <action android:name="com.gdelataillade.alarm.action.RING" />
        <category android:name="android.intent.category.DEFAULT" />
    </intent-filter>
</activity>
```

A launcher tap then arrives as `ACTION_MAIN` and an alarm as `ACTION_RING`, so
the action alone tells them apart — no timing heuristics — and the
[alarm extras](https://github.com/gdelataillade/alarm/blob/main/README.md#presenting-the-alarm-on-your-own-screen)
come with it:

```kotlin
import com.gdelataillade.alarm.alarm.AlarmService

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        if (intent.action != AlarmService.ACTION_RING) return
        val alarmId = intent.getIntExtra(AlarmService.EXTRA_ALARM_ID, -1)
        // An alarm opened the app. Stash this for Dart to read.
    }
}
```

A cold launch arrives in `onCreate`, and a launch while your app is already
running arrives in `onNewIntent`.

## Two things to get right

`setIntent(intent)` matters: without it anything that later reads `getIntent()`
still sees the intent the activity was created with.

Don't push the value straight to Dart from `onCreate`. The engine exists by then,
but Dart `main()` has not run, so a `MethodChannel` message can arrive before
there is a handler for it. Hold the value natively and expose it through a
`setMethodCallHandler` that Dart calls once it is ready.

## The trade-off

Declaring both filters keeps your app in one task, which is the point when you
want your normal UI to present the alarm — but it also means the alarm no longer
returns the user to what they were doing when your screen finishes. Declare a
separate activity with its own `taskAffinity` if you want that instead.

Declaring no such activity keeps the default behaviour: the launcher activity is
opened, with no extras.
