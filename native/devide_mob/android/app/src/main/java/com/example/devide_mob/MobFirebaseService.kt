package com.example.devide_mob

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.mob.plugin.MobNotifyHub
import org.json.JSONObject

class MobFirebaseService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        val pid = MobNotifyHub.notifyPid
        if (pid != 0L) {
            MobBridge.nativeDeliverPushToken(pid, token)
        } else {
            MobNotifyHub.pendingToken = token
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val json = notificationJson(message)
        val pid = MobNotifyHub.notifyPid

        if (pid != 0L) {
            MobBridge.nativeDeliverNotification(pid, json)
        } else {
            postNotification(json)
        }
    }

    private fun notificationJson(message: RemoteMessage): String {
        message.data["mob_notification_json"]?.takeIf { it.isNotBlank() }?.let { return it }

        val data = JSONObject()
        for ((key, value) in message.data) data.put(key, value)

        return JSONObject().apply {
            put("id", message.messageId ?: "push-${System.currentTimeMillis()}")
            put("title", message.notification?.title ?: message.data["title"] ?: "Session alert")
            put("body", message.notification?.body ?: message.data["body"] ?: "Tap to open the session.")
            put("source", "push")
            put("data", data)
        }.toString()
    }

    private fun postNotification(json: String) {
        val payload = JSONObject(json)
        val id = payload.optString("id", "mob_push")
        val title = payload.optString("title", "Session alert")
        val body = payload.optString("body", "Tap to open the session.")

        ensureChannel()

        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("mob_notification_json", json)
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            id.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, MobNotifyHub.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(id.hashCode(), notification)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(
                    MobNotifyHub.CHANNEL_ID,
                    "Notifications",
                    NotificationManager.IMPORTANCE_DEFAULT
                )
            )
        }
    }
}
