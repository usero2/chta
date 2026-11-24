package app.cht.cht

import android.content.Context
import android.content.Intent
import android.app.NotificationManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** One retained engine: Activity recreation must not create a second account. */
object ChatRuntime {
    var engine: FlutterEngine? = null
    var channel: MethodChannel? = null
    var networkMonitor: ChatNetworkMonitor? = null
    var running = false
        private set

    fun showLockAction(context: Context): Boolean =
        context.getSharedPreferences("cht.runtime", Context.MODE_PRIVATE)
            .getBoolean("showLockAction", true)

    fun configure(context: Context, active: Boolean, enabled: Boolean?,
                  showLockAction: Boolean?): Map<String, Boolean> {
        val prefs = context.getSharedPreferences("cht.runtime", Context.MODE_PRIVATE)
        if (enabled != null) prefs.edit().putBoolean("enabled", enabled).apply()
        if (showLockAction != null) {
            prefs.edit().putBoolean("showLockAction", showLockAction).apply()
        }
        val keepAlive = prefs.getBoolean("enabled", true)
        if (active && keepAlive) {
            val intent = Intent(context, ChatReceiveService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
            running = true
        } else {
            running = false
            context.stopService(Intent(context, ChatReceiveService::class.java))
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        val channelEnabled = Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel("cht.receive")?.importance != NotificationManager.IMPORTANCE_NONE
        return mapOf("enabled" to keepAlive, "running" to running,
            "notificationVisible" to (manager.areNotificationsEnabled() && channelEnabled),
            "showLockAction" to this.showLockAction(context))
    }
}
