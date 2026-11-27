package app.cht.cht

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.LinkProperties
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Connectivity is a recovery hint, never proof of a usable chat route. */
class ChatNetworkMonitor(context: Context) : EventChannel.StreamHandler {
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    private var lastSnapshot: Map<String, Any>? = null
    private val deliver = Runnable {
        val current = snapshot()
        if (current != lastSnapshot) {
            lastSnapshot = current
            sink?.success(current)
        }
    }

    fun snapshot(): Map<String, Any> {
        val network = manager.activeNetwork
        val caps = network?.let { manager.getNetworkCapabilities(it) }
        val transports = (0..7).filter { caps?.hasTransport(it) == true }.joinToString(",")
        val addresses = network?.let { manager.getLinkProperties(it) }
            ?.linkAddresses?.map { it.toString() }?.sorted()?.joinToString(",").orEmpty()
        // Captive-portal validation may change without moving the socket to
        // another network. The network handle and interface addresses are stable.
        return mapOf("available" to (network != null),
            "fingerprint" to "${network?.networkHandle ?: 0}:$transports:${addresses.hashCode()}")
    }
    private fun emit() {
        main.removeCallbacks(deliver)
        main.post(deliver)
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        sink = events
        val observer = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { emit() }
            override fun onLost(network: Network) { emit() }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { emit() }
            override fun onLinkPropertiesChanged(network: Network, link: LinkProperties) { emit() }
        }
        callback = observer
        manager.registerDefaultNetworkCallback(observer)
        emit()
    }
    override fun onCancel(arguments: Any?) {
        main.removeCallbacks(deliver)
        lastSnapshot = null
        sink = null
        callback?.let { try { manager.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        callback = null
    }
}
