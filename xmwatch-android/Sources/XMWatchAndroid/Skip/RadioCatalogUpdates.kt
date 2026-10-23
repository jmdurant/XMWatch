package xmwatch.android

import android.os.Handler
import android.os.Looper

/** Coalesced app catalog invalidation; never starts a service or signs in. */
object RadioCatalogUpdates {
    private val handler=Handler(Looper.getMainLooper())
    private val listeners=mutableSetOf<()->Unit>()
    private var scheduled=false
    private val deliver=Runnable {
        scheduled=false
        listeners.toList().forEach { if (it in listeners) it() }
    }
    fun add(listener:()->Unit) { listeners.add(listener) }
    fun remove(listener:()->Unit) { listeners.remove(listener) }
    fun changed() {
        if (Looper.myLooper()!=Looper.getMainLooper()) { handler.post { changed() };return }
        if (!scheduled) { scheduled=true;handler.postDelayed(deliver,50) }
    }
}
