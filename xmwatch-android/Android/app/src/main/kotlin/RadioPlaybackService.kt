package xmwatch.android

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.media3.common.Player
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.*
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.collect.ImmutableList
import androidx.media3.session.MediaLibraryService.MediaLibrarySession

@UnstableApi
class RadioPlaybackService : MediaLibraryService() {
    private var session: MediaLibrarySession? = null
    private val engine get() = RadioEngine.get(this)
    private val access by lazy { ControllerAccessPolicy.forContext(this) }
    private val catalog = MediaLibraryCatalog(artwork = { ControllerArtwork.get(this).address(it) }) { request, done ->
        XMWatchAndroidAppDelegate.shared.onBrowseLibrary(request, done)
    }
    private val subscriptions=mutableMapOf<MediaSession.ControllerInfo,MutableSet<String>>()
    private val searches=mutableMapOf<MediaSession.ControllerInfo,MutableSet<String>>()
    private var catalogRevision=0L
    private val catalogListener:()->Unit={ refreshSubscriptions() }
    private fun refreshSubscriptions() {
        val current=session ?: return
        val revision=++catalogRevision
        for ((controller,ids) in subscriptions.toMap()) for (id in ids.toList()) {
            com.google.common.util.concurrent.Futures.addCallback(catalog.children(id,0,100,null),object:com.google.common.util.concurrent.FutureCallback<LibraryResult<ImmutableList<MediaItem>>> {
                override fun onSuccess(result:LibraryResult<ImmutableList<MediaItem>>?) {
                    if (session!==current || revision!=catalogRevision || subscriptions[controller]?.contains(id)!=true) return
                    current.notifyChildrenChanged(controller,id,if (result?.resultCode==0) result.value?.size ?: 0 else 0,null)
                }
                override fun onFailure(error:Throwable) {}
            },mainExecutor)
        }
        for ((controller,queries) in searches.toMap()) for (query in queries.toList()) {
            com.google.common.util.concurrent.Futures.addCallback(catalog.searchCount(query),object:com.google.common.util.concurrent.FutureCallback<Int> {
                override fun onSuccess(count:Int?) {
                    if (session!==current || revision!=catalogRevision || searches[controller]?.contains(query)!=true) return
                    current.notifySearchResultChanged(controller,query,(count ?: 0).coerceAtLeast(0),null)
                }
                override fun onFailure(error:Throwable) {}
            },mainExecutor)
        }
    }
    private val callback by lazy { object : ControllerAccessCallback(access) {
        override fun onGetLibraryRoot(session: MediaLibrarySession, controller: MediaSession.ControllerInfo, params: LibraryParams?): ListenableFuture<LibraryResult<MediaItem>> =
            Futures.immediateFuture(LibraryResult.ofItem(MediaLibraryCatalog.root, params))
        override fun onSubscribe(session:MediaLibrarySession,controller:MediaSession.ControllerInfo,id:String,params:LibraryParams?):ListenableFuture<LibraryResult<Void>> {
            if (!id.startsWith("media:v1:") || id.length>4096) return Futures.immediateFuture(LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE))
            val ids=subscriptions.getOrPut(controller) { mutableSetOf() }
            if (ids.size>=128 && id !in ids) return Futures.immediateFuture(LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE))
            ids.add(id);refreshSubscriptions()
            return Futures.immediateFuture(LibraryResult.ofVoid(params))
        }
        override fun onUnsubscribe(session:MediaLibrarySession,controller:MediaSession.ControllerInfo,id:String):ListenableFuture<LibraryResult<Void>> {
            subscriptions[controller]?.remove(id)
            return Futures.immediateFuture(LibraryResult.ofVoid())
        }
        override fun onDisconnected(session:MediaSession,controller:MediaSession.ControllerInfo) {
            subscriptions.remove(controller);searches.remove(controller)
            super.onDisconnected(session,controller)
        }
        override fun onGetItem(session: MediaLibrarySession, controller: MediaSession.ControllerInfo, id: String): ListenableFuture<LibraryResult<MediaItem>> = catalog.item(id, null)
        override fun onGetChildren(session: MediaLibrarySession, controller: MediaSession.ControllerInfo, id: String, page: Int, size: Int, params: LibraryParams?): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = catalog.children(id, page, size, params)
        override fun onSearch(session: MediaLibrarySession, controller: MediaSession.ControllerInfo, query: String, params: LibraryParams?): ListenableFuture<LibraryResult<Void>> =
            Futures.transform(catalog.searchCount(query), { count ->
                if (!query.isBlank() && query.length<=256 && (searches[controller]?.size ?: 0)<64) searches.getOrPut(controller) { mutableSetOf() }.add(query)
                session.notifySearchResultChanged(controller, query, (count ?: -1).coerceAtLeast(0), params)
                if (count == null || count < 0) LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE) else LibraryResult.ofVoid(params)
            }, mainExecutor)
        override fun onGetSearchResult(session: MediaLibrarySession, controller: MediaSession.ControllerInfo, query: String, page: Int, size: Int, params: LibraryParams?): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = catalog.search(query, page, size, params)
        override fun onSetMediaItems(session: MediaSession, controller: MediaSession.ControllerInfo, items: List<MediaItem>, index: Int, position: Long): ListenableFuture<MediaSession.MediaItemsWithStartPosition> = RadioControllerPreparation.select(items, index, position)
        override fun onPlaybackResumption(session: MediaSession, controller: MediaSession.ControllerInfo, isForPlayback: Boolean): ListenableFuture<MediaSession.MediaItemsWithStartPosition> =
            if (isForPlayback) RadioControllerPreparation.select(listOf(MediaItem.Builder().setMediaId(MediaLibraryCatalog.RESUME_ID).build()), 0, androidx.media3.common.C.TIME_UNSET)
            else Futures.transformAsync(catalog.resumption(), { saved ->
                if (saved == null) Futures.immediateFailedFuture(IllegalStateException("No saved channel")) else Futures.immediateFuture(saved)
            }, mainExecutor)
        override fun onPlayerCommandRequest(session: MediaSession, controller: MediaSession.ControllerInfo, command: Int): Int {
            if (command in listOf(Player.COMMAND_STOP, Player.COMMAND_PLAY_PAUSE)) {
                // Pause itself is handled by the player so Play remains usable.
                if (command == Player.COMMAND_STOP) RadioControllerPreparation.cancel()
            }
            return SessionResult.RESULT_SUCCESS
        }
    } }
    private fun openPlayer() = PendingIntent.getActivity(this, 1,
        Intent(this, MainActivity::class.java).setAction("xmwatch.OPEN_NOW_PLAYING")
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    override fun onCreate() {
        super.onCreate()
        RadioControllerPreparation.initialize(this)
        session = MediaLibrarySession.Builder(this, engine.sessionPlayer, callback).setSessionActivity(openPlayer()).build()
        addSession(checkNotNull(session))
        RadioCatalogUpdates.add(catalogListener)
    }
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? =
        if (access.canRoute(controllerInfo, packageName)) session else null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "xmwatch.CANCEL") {
            engine.noteInterruption("stop"); engine.pause(); stopSelf(); return START_NOT_STICKY
        }
        if (intent?.action == "xmwatch.PREPARE") { showPreparing(); return START_NOT_STICKY }
        return super.onStartCommand(intent, flags, startId)
    }
    override fun onUpdateNotificationAsync(session: MediaSession, required: Boolean): ListenableFuture<Void?> {
        if (engine.preparing && engine.player.playbackState == Player.STATE_IDLE) {
            showPreparing(); return Futures.immediateVoidFuture()
        }
        return super.onUpdateNotificationAsync(session, required)
    }
    private fun showPreparing() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("radio-preparing", "Radio playback", NotificationManager.IMPORTANCE_LOW))
        val notification = NotificationCompat.Builder(this, "radio-preparing")
            .setSmallIcon(android.R.drawable.ic_media_play).setContentTitle("Connecting to channel")
            .setContentText("XMWatch").setOngoing(true).setSilent(true)
            .setContentIntent(openPlayer())
            .addAction(android.R.drawable.ic_media_pause, "Cancel", PendingIntent.getService(this, 2,
                Intent(this, RadioPlaybackService::class.java).setAction("xmwatch.CANCEL"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)).build()
        ServiceCompat.startForeground(this, DefaultMediaNotificationProvider.DEFAULT_NOTIFICATION_ID,
            notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
    }
    override fun onDestroy() {
        RadioCatalogUpdates.remove(catalogListener);++catalogRevision
        subscriptions.clear();searches.clear()
        RadioControllerPreparation.cancel(); catalog.close()
        session?.let { removeSession(it); it.release() }; session = null
        engine.noteInterruption("stop"); engine.pause()
        super.onDestroy()
    }
}
