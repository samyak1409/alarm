package com.gdelataillade.alarm.services

import com.gdelataillade.alarm.models.AlarmSettings

import android.content.Context
import io.flutter.Log
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString

const val SHARED_PREFERENCES_NAME = "AlarmSharedPreferences"

private val Context.dataStore: DataStore<Preferences> by
preferencesDataStore(SHARED_PREFERENCES_NAME)

class AlarmStorage(context: Context) {
    companion object {
        private const val TAG = "AlarmStorage"
        private const val PREFIX = "__alarm_id__"
        private const val SNOOZE_PREFIX = "__snoozed_alarm_id__"

        // How long past its ring time a marker Dart never applied is kept
        // before being discarded as unapplicable.
        private const val SNOOZE_MARKER_TTL_MILLIS = 7L * 24 * 60 * 60 * 1000

        private const val WARNING_TITLE_KEY = "notificationOnAppKillTitle"
        private const val WARNING_BODY_KEY = "notificationOnAppKillBody"
    }

    private val dataStore = context.dataStore

    fun saveAlarm(alarmSettings: AlarmSettings) {
        return runBlocking {
            val key = stringPreferencesKey("$PREFIX${alarmSettings.id}")
            val value = Json.encodeToString(alarmSettings)
            dataStore.edit { preferences -> preferences[key] = value }
        }
    }

    fun unsaveAlarm(id: Int) {
        return runBlocking {
            val key = stringPreferencesKey("$PREFIX$id")
            val snoozeKey = stringPreferencesKey("$SNOOZE_PREFIX$id")
            dataStore.edit { preferences ->
                preferences.remove(key)
                // A stopped alarm is no longer owed, so any pending deferral for
                // it is moot. Left behind, the marker would reappear on the next
                // Alarm.init() and try to resurrect an alarm the user dismissed.
                preferences.remove(snoozeKey)
            }
        }
    }

    fun getSavedAlarms(): List<AlarmSettings> {
        return runBlocking {
            val preferences = dataStore.data.map { prefs ->
                prefs.asMap().filterKeys { it.name.startsWith(PREFIX) }
            }.first()

            val alarms = mutableListOf<AlarmSettings>()
            preferences.forEach { (key, value) ->
                if (value is String) {
                    try {
                        val alarm = Json.decodeFromString<AlarmSettings>(value)
                        alarms.add(alarm)
                    } catch (e: Exception) {
                        // Fall back to the lenient parser, which understands
                        // payloads written by older plugin versions, instead
                        // of silently dropping the alarm.
                        try {
                            alarms.add(AlarmSettings.fromJson(value))
                            Log.w(TAG, "Recovered alarm for key ${key.name} with legacy parser.")
                        } catch (e2: Exception) {
                            Log.e(
                                TAG,
                                "Error parsing alarm settings for key ${key.name}: ${e2.message}"
                            )
                        }
                    }
                } else {
                    Log.w(TAG, "Skipping non-alarm preference with key: ${key.name}")
                }
            }
            alarms
        }
    }

    /**
     * Records that [id] was deferred until [nextRingAtMillis].
     *
     * A snooze is normally taken with no Flutter engine running, because the
     * notification and the ringing screen are native. Holding the deferral
     * here is what lets the next isolate learn about it instead of finding an
     * alarm that silently moved.
     */
    fun saveSnooze(id: Int, nextRingAtMillis: Long) {
        return runBlocking {
            val key = stringPreferencesKey("$SNOOZE_PREFIX$id")
            dataStore.edit { preferences ->
                preferences[key] = nextRingAtMillis.toString()
            }
        }
    }

    /**
     * Reads every pending snooze marker, keyed by alarm id.
     *
     * Non-destructive on purpose: a marker survives until [acknowledgeSnooze]
     * confirms Dart durably applied it, so a read followed by a crash loses
     * nothing. Markers older than [SNOOZE_MARKER_TTL_MILLIS] are dropped, so a
     * marker Dart can never apply cannot accumulate forever.
     */
    fun getPendingSnoozes(): Map<Int, Long> {
        return runBlocking {
            val stored = dataStore.data.map { prefs ->
                prefs.asMap().filterKeys { it.name.startsWith(SNOOZE_PREFIX) }
            }.first()

            val snoozes = mutableMapOf<Int, Long>()
            val expired = mutableListOf<Preferences.Key<*>>()
            val now = System.currentTimeMillis()
            stored.forEach { (key, value) ->
                val id = key.name.removePrefix(SNOOZE_PREFIX).toIntOrNull()
                val nextRingAt = (value as? String)?.toLongOrNull()
                if (id == null || nextRingAt == null) {
                    Log.w(TAG, "Dropping unreadable snooze marker: ${key.name}")
                    expired.add(key)
                } else if (now - nextRingAt > SNOOZE_MARKER_TTL_MILLIS) {
                    Log.w(TAG, "Dropping snooze marker for $id, stale since $nextRingAt.")
                    expired.add(key)
                } else {
                    snoozes[id] = nextRingAt
                }
            }

            if (expired.isNotEmpty()) {
                dataStore.edit { preferences ->
                    expired.forEach { preferences.remove(it) }
                }
            }
            snoozes
        }
    }

    /**
     * Drops the marker for [id], but only if it still records exactly
     * [nextRingAtMillis].
     *
     * Comparing the timestamp as well as the id means a late acknowledgement
     * for an earlier snooze cannot discard a newer one taken for the same alarm
     * in the meantime.
     */
    fun acknowledgeSnooze(id: Int, nextRingAtMillis: Long) {
        return runBlocking {
            val key = stringPreferencesKey("$SNOOZE_PREFIX$id")
            dataStore.edit { preferences ->
                if (preferences[key] == nextRingAtMillis.toString()) {
                    preferences.remove(key)
                } else {
                    Log.d(TAG, "Not acknowledging snooze $id: marker moved on.")
                }
            }
        }
    }

    /**
     * Persists the kill-warning notification text.
     *
     * Held here rather than in memory because the context that has to show the
     * warning is often not the one that was told what it should say — a snooze
     * taken from a notification runs with no engine and no plugin instance.
     */
    fun saveWarningNotificationText(title: String, body: String) {
        return runBlocking {
            dataStore.edit { preferences ->
                preferences[stringPreferencesKey(WARNING_TITLE_KEY)] = title
                preferences[stringPreferencesKey(WARNING_BODY_KEY)] = body
            }
        }
    }

    /** The stored kill-warning text, or null when the app never set any. */
    fun getWarningNotificationText(): Pair<String, String>? {
        return runBlocking {
            val prefs = dataStore.data.first()
            val title = prefs[stringPreferencesKey(WARNING_TITLE_KEY)]
            val body = prefs[stringPreferencesKey(WARNING_BODY_KEY)]
            if (title == null || body == null) null else title to body
        }
    }

    /** Removes any pending snooze marker for [id], whatever it records. */
    fun clearSnooze(id: Int) {
        return runBlocking {
            val key = stringPreferencesKey("$SNOOZE_PREFIX$id")
            dataStore.edit { preferences -> preferences.remove(key) }
        }
    }
}
