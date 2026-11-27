package app.cht.cht

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel

/** Keeps the existing Dart messaging isolate alive; never unlocks an identity. */
class ChatReceiveService : Service() {
    companion object {
        const val NOTIFICATION_CHANNEL_ID = "cht.receive"

        @TargetApi(Build.VERSION_CODES.O)
        fun createNotificationChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID, "Background reception", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Status while chta receives messages in the background"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        ChatRuntime.serviceStopped()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (ChatRuntime.engine == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val immutable = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(this, 8101,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), immutable)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            createNotificationChannel(this)
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        val showLockAction = ChatRuntime.showLockAction(this)
        builder.setSmallIcon(R.drawable.ic_chat_receive)
            .setContentTitle("chta").setContentText("Receiving messages")
            .setContentIntent(open).setOngoing(true).setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_DEFERRED)
        }
        if (showLockAction) {
            val lock = PendingIntent.getService(this, 8102,
                Intent(this, ChatReceiveService::class.java).setAction("app.cht.LOCK"), immutable)
            builder.addAction(Notification.Action.Builder(null, "Lock app", lock).build())
        }
        val notification = builder.build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(8100, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else startForeground(8100, notification)
        if (showLockAction && intent?.action == "app.cht.LOCK") {
            ChatRuntime.channel?.invokeMethod("lockRequested", null, object : MethodChannel.Result {
                override fun success(result: Any?) { if (result == true) stopSelf() }
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        }
        // No sticky restart: a killed process may require the owner's PIN.
        return START_NOT_STICKY
    }
}
