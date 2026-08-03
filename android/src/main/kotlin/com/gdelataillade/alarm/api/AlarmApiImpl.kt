package com.gdelataillade.alarm.api

import com.gdelataillade.alarm.generated.AlarmApi
import com.gdelataillade.alarm.generated.AlarmSettingsWire
import com.gdelataillade.alarm.generated.PendingSnoozeWire
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.gdelataillade.alarm.alarm.AlarmPlugin
import com.gdelataillade.alarm.alarm.AlarmReceiver
import com.gdelataillade.alarm.alarm.AlarmService
import com.gdelataillade.alarm.models.AlarmSettings
import com.gdelataillade.alarm.services.AlarmScheduler
import com.gdelataillade.alarm.services.AlarmStorage
import com.gdelataillade.alarm.services.NotificationHandler
import com.gdelataillade.alarm.services.WarningNotificationState
import io.flutter.Log

class AlarmApiImpl(private val context: Context) : AlarmApi {
    companion object {
        private const val TAG = "AlarmApiImpl"
    }

    private val alarmIds: MutableList<Int> = mutableListOf()

    override fun setAlarm(alarmSettings: AlarmSettingsWire, callback: (Result<Unit>) -> Unit) {
        setAlarm(AlarmSettings.fromWire(alarmSettings))
        callback(Result.success(Unit))
    }

    override fun stopAlarm(alarmId: Long, callback: (Result<Unit>) -> Unit) {
        val id = alarmId.toInt()

        // Deliver the stop to the running service so it can clean up ringing
        // alarms and dequeue if needed. If the service isn't running, there is
        // nothing to ring/dequeue and storage cleanup below is sufficient.
        val serviceIsRunning = AlarmService.instance != null
        AlarmService.instance?.handleStopAlarmCommand(id)

        // Intent to cancel the future alarm if it's set
        val alarmIntent = Intent(context, AlarmReceiver::class.java)
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            id,
            alarmIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Cancel the future alarm using AlarmManager
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(pendingIntent)

        alarmIds.remove(id)
        AlarmStorage(context).unsaveAlarm(id)
        WarningNotificationState.refresh(context)

        // If the service was running it is the responsibility of the AlarmService to send the stop
        // signal to Flutter.
        if (!serviceIsRunning) {
            // No foreground service owns the notification here, so a lingering
            // one must be cancelled explicitly.
            NotificationHandler(context).cancelNotification(id)
            // Notify the plugin about the alarm being stopped.
            AlarmPlugin.alarmTriggerApi?.alarmStopped(id.toLong()) {
                if (it.isSuccess) {
                    Log.d(
                        TAG,
                        "Alarm stopped notification for $id was processed successfully by Flutter."
                    )
                } else {
                    Log.d(TAG, "Alarm stopped notification for $id encountered error in Flutter.")
                }
            }
        }
        callback(Result.success(Unit))
    }

    override fun stopAll(callback: (Result<Unit>) -> Unit) {
        for (alarm in AlarmStorage(context).getSavedAlarms()) {
            stopAlarm(alarm.id.toLong()) {}
        }
        val alarmIdsCopy = alarmIds.toList()
        for (alarmId in alarmIdsCopy) {
            stopAlarm(alarmId.toLong()) {}
        }
        callback(Result.success(Unit))
    }

    override fun isRinging(alarmId: Long?): Boolean {
        val ringingAlarmIds = AlarmService.ringingAlarmIds
        if (alarmId == null) {
            return ringingAlarmIds.isNotEmpty()
        }
        return ringingAlarmIds.contains(alarmId.toInt())
    }

    override fun setWarningNotificationOnKill(title: String, body: String) {
        WarningNotificationState.setText(context, title, body)

        // Re-create so the new text takes effect if it is already showing.
        WarningNotificationState.disable(context)
        WarningNotificationState.refresh(context)
    }

    override fun disableWarningNotificationOnKill() {
        WarningNotificationState.disable(context)
    }

    override fun getPendingSnoozes(callback: (Result<List<PendingSnoozeWire>>) -> Unit) {
        val snoozes = AlarmStorage(context).getPendingSnoozes()
        callback(
            Result.success(
                snoozes.map { (id, nextRingAt) ->
                    PendingSnoozeWire(id.toLong(), nextRingAt)
                }
            )
        )
    }

    override fun acknowledgeSnooze(
        alarmId: Long,
        nextRingAtMillis: Long,
        callback: (Result<Unit>) -> Unit,
    ) {
        AlarmStorage(context).acknowledgeSnooze(alarmId.toInt(), nextRingAtMillis)
        callback(Result.success(Unit))
    }

    fun setAlarm(alarm: AlarmSettings) {
        if (alarmIds.contains(alarm.id)) {
            Log.w(TAG, "Stopping alarm with identical ID=${alarm.id} before scheduling a new one.")
            stopAlarm(alarm.id.toLong()) {}
        }

        alarmIds.add(alarm.id)

        // Persisting and arming live in AlarmScheduler so the snooze path can
        // reuse them without also inheriting the stop-and-replace preamble
        // above, which would report the deferral to Flutter as a stop.
        AlarmScheduler.schedule(context, alarm)
    }

}
