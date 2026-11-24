package app.cht.cht

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel

/** Keeps the existing Dart messaging isolate alive; never unlocks an identity. */
class ChatReceiveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (ChatRuntime.engine == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                "cht.receive", "Background reception", NotificationManager.IMPORTANCE_LOW))
        }
        val immutable = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(this, 8101,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), immutable)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "cht.receive")
            else Notification.Builder(this)
        val showLockAction = ChatRuntime.showLockAction(this)
        builder.setSmallIcon(R.drawable.ic_chat_receive)
            .setContentTitle("chta").setContentText("Receiving messages")
            .setContentIntent(open).setOngoing(true).setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
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
