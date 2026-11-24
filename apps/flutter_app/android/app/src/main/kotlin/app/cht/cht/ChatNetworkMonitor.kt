package app.cht.cht

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Connectivity is a recovery hint, never proof of a usable chat route. */
class ChatNetworkMonitor(context: Context) : EventChannel.StreamHandler {
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    fun snapshot(): Map<String, Any> {
        val network = manager.activeNetwork
        val caps = network?.let { manager.getNetworkCapabilities(it) }
        val transports = (0..7).filter { caps?.hasTransport(it) == true }.joinToString(",")
        val validated = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        return mapOf("available" to (network != null),
            "fingerprint" to "${network?.networkHandle ?: 0}:$transports:$validated")
    }
    private fun emit() {
        main.post { sink?.success(snapshot()) }
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        sink = events
        val observer = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { emit() }
            override fun onLost(network: Network) { emit() }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { emit() }
        }
        callback = observer
        manager.registerDefaultNetworkCallback(observer)
        emit()
    }
    override fun onCancel(arguments: Any?) {
        sink = null
        callback?.let { try { manager.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        callback = null
    }
}
