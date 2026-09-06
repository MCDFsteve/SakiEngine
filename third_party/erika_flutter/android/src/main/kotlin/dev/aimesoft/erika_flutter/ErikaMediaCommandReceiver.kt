package dev.aimesoft.erika_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ErikaMediaCommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ErikaMediaSession.ACTION_PLAY -> dispatch(ErikaMediaSession.ACTION_PLAY)
            ErikaMediaSession.ACTION_PAUSE -> dispatch(ErikaMediaSession.ACTION_PAUSE)
            ErikaMediaSession.ACTION_STOP -> dispatch(ErikaMediaSession.ACTION_STOP)
        }
    }

    internal companion object {
        private val handlers = LinkedHashMap<Any, (String) -> Unit>()
        private val activationOrder = LinkedHashSet<Any>()

        @Synchronized
        fun register(owner: Any, handler: (String) -> Unit) {
            handlers[owner] = handler
        }

        @Synchronized
        fun activate(owner: Any) {
            if (!handlers.containsKey(owner)) {
                return
            }
            activationOrder.remove(owner)
            activationOrder.add(owner)
        }

        @Synchronized
        fun deactivate(owner: Any) {
            activationOrder.remove(owner)
        }

        @Synchronized
        fun unregister(owner: Any) {
            activationOrder.remove(owner)
            handlers.remove(owner)
        }

        private fun dispatch(action: String) {
            val handler = synchronized(this) {
                activationOrder.lastOrNull()?.let(handlers::get)
            }
            handler?.invoke(action)
        }
    }
}
