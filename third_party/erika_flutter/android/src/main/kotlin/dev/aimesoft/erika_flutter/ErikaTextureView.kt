package dev.aimesoft.erika_flutter

import android.annotation.TargetApi
import android.content.Context
import android.graphics.SurfaceTexture
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.function.Consumer
import kotlin.math.max

internal class ErikaAndroidVideoViewFactory(
    private val plugin: ErikaFlutterPlugin,
    private val useHdrSurface: Boolean = false,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val creationParams = args as? Map<String, Any?> ?: emptyMap()
        return ErikaAndroidVideoView(
            context,
            viewId,
            creationParams,
            plugin,
            useHdrSurface,
        )
    }
}

internal class ErikaAndroidVideoView(
    context: Context,
    val viewId: Int,
    creationParams: Map<String, Any?>,
    private val plugin: ErikaFlutterPlugin,
    private val useHdrSurface: Boolean,
) : PlatformView,
    TextureView.SurfaceTextureListener,
    SurfaceHolder.Callback2 {
    private val textureView = if (useHdrSurface) null else TextureView(context)
    private val surfaceView = if (useHdrSurface) SurfaceView(context) else null
    private val nativeView: View = surfaceView ?: requireNotNull(textureView)
    private val rawRequestedHdrHeadroom =
        (creationParams["requestedHdrHeadroom"] as? Number)?.toFloat()
    private val requestedHdrHeadroom = androidDesiredHdrHeadroom(rawRequestedHdrHeadroom)
    private val hybridComposition = creationParams["composition"] == "hybrid"
    private val videoAlphaMode =
        (creationParams["videoAlphaMode"] as? Number)?.toInt() ?: 0
    private val mainHandler = Handler(Looper.getMainLooper())
    private var outputSurface: Surface? = null
    private var ownsOutputSurface = false
    private val deferredSurfaceReleases = mutableListOf<Surface>()
    private var outputSurfaceTexture: SurfaceTexture? = null
    private val deferredSurfaceTextureReleases = mutableListOf<SurfaceTexture>()
    private var surfacePixelWidth = 0
    private var surfacePixelHeight = 0
    private var boundHost: AndroidPlayerHost? = null
    private val hostsAwaitingNativeDestroy = mutableSetOf<AndroidPlayerHost>()
    private var pendingBind: PendingViewBind? = null
    private val pendingBindCompletions = mutableListOf<PendingViewCompletion>()
    private val pendingUnbindCompletions = mutableListOf<PendingViewCompletion>()
    private var nativeAttachPending = false
    private var nativeDetachPending = false
    private var nativeResizePending = false
    private var pendingResizeRequest: PendingSurfaceResize? = null
    private var nativeDetachRetryPending = false
    private var lifecycleSurfaceSuspended = false
    private var lifecycleDetachPending = false
    private var unbindRequested = false
    private var disposeRequested = false
    private var disposed = false
    private val surfaceBindingGenerations = AndroidSurfaceBindingGenerationTracker()
    private val surfaceRecoveryTokens = AndroidSurfaceRecoveryTokenSource()
    private val surfaceRecoveryAttempts = AndroidSurfaceRecoveryAttemptTracker()
    private var surfaceRecoveryRunnable: Runnable? = null
    private var observedHdrDisplay: Display? = null
    private var hdrRatioListenerRegistered = false
    private var attachedDisplayId: Int? = null
    private var attachedDisplayHdrSupported: Boolean? = null
    private var lastPublishedHdrHeadroom: AndroidHdrHeadroomState? = null
    private val hdrRatioListener = Consumer<Display> {
        mainHandler.post { refreshHdrHeadroomObservation() }
    }
    private val attachStateListener = object : View.OnAttachStateChangeListener {
        override fun onViewAttachedToWindow(view: View) {
            mainHandler.post {
                if (disposed || disposeRequested) {
                    return@post
                }
                val host = boundHost
                if (host != null && !host.surfaceAttached) {
                    val attempt = attachIfReady(host)
                    handleImmediateAttempt(host, attempt)
                }
                refreshHdrHeadroomObservation()
            }
        }

        override fun onViewDetachedFromWindow(view: View) {
            stopHdrHeadroomObservation(publishUnknown = true)
        }
    }

    internal val boundPlayerHost: AndroidPlayerHost?
        get() = boundHost

    internal val isExtendedLinearSurface: Boolean
        get() = useHdrSurface

    init {
        if (rawRequestedHdrHeadroom != null && rawRequestedHdrHeadroom != requestedHdrHeadroom) {
            Log.w(
                TAG,
                "invalid requestedHdrHeadroom=$rawRequestedHdrHeadroom for viewId=$viewId; " +
                    "using 0 (system auto), expected 0 or [1, 10000]",
            )
        }
        textureView?.apply {
            isOpaque = videoAlphaMode == 0
            surfaceTextureListener = this@ErikaAndroidVideoView
        }
        surfaceView?.apply {
            holder.setFormat(PixelFormat.RGBA_F16)
            holder.addCallback(this@ErikaAndroidVideoView)
            if (Build.VERSION.SDK_INT >= 35) {
                runCatching { setDesiredHdrHeadroom(requestedHdrHeadroom) }
                    .onFailure { error ->
                        Log.w(
                            TAG,
                            "setDesiredHdrHeadroom failed viewId=$viewId requested=$requestedHdrHeadroom",
                            error,
                        )
                    }
            }
        }
        nativeView.addOnAttachStateChangeListener(attachStateListener)
        nativeView.contentDescription = creationParams["debugLabel"] as? String
        plugin.registerVideoView(this)
    }

    override fun getView(): View = nativeView

    override fun dispose() {
        if (disposed) {
            return
        }
        disposeRequested = true
        val host = boundHost
        if (host == null) {
            cancelSurfaceRecovery()
            finishDispose()
            return
        }
        unbind(host)
    }

    private fun finishDispose() {
        if (disposed) {
            return
        }
        stopHdrHeadroomObservation(publishUnknown = false)
        cancelSurfaceRecovery()
        disposed = true
        failPendingBind(
            NativeResponse(false, -1, "Android video view $viewId was disposed", null),
        )
        failAllViewCompletions("Android video view $viewId was disposed")
        nativeDetachRetryPending = false
        lifecycleDetachPending = false
        lifecycleSurfaceSuspended = false
        unbindRequested = false
        releaseSurface()
        releaseDeferredSurfacesIfIdle()
        textureView?.surfaceTextureListener = null
        surfaceView?.holder?.removeCallback(this)
        nativeView.removeOnAttachStateChangeListener(attachStateListener)
        plugin.unregisterVideoView(this)
    }

    fun bind(host: AndroidPlayerHost): NativeResponse {
        val renewingBinding = boundHost === host &&
            (unbindRequested || lifecycleSurfaceSuspended || lifecycleDetachPending)
        if (renewingBinding) {
            advanceSurfaceBindingGeneration(host)
        }
        lifecycleSurfaceSuspended = false
        if (disposed || disposeRequested) {
            return NativeResponse(false, -1, "Android video view $viewId is disposed", null)
        }
        if (boundHost !== host) {
            boundHost?.let { currentHost ->
                clearPendingBind()
                val response = unbind(currentHost)
                if (!response.ok) {
                    return response
                }
                if (boundHost === currentHost) {
                    queuePendingBind(host, this)
                    return NativeResponse.success()
                }
            }
            host.attachedView?.takeIf { it !== this }?.let { previousView ->
                previousView.clearPendingBind()
                val response = previousView.unbind(host)
                if (!response.ok) {
                    return response
                }
                if (host.attachedView === previousView) {
                    previousView.queuePendingBind(host, this)
                    return NativeResponse.success()
                }
            }
            boundHost = host
            host.attachedView = this
            lastPublishedHdrHeadroom = null
            advanceSurfaceBindingGeneration(host)
        }
        unbindRequested = false
        cancelSurfaceRecovery()
        val attempt = attachIfReady(host)
        handleImmediateAttempt(host, attempt)
        refreshHdrHeadroomObservation()
        plugin.onPlayerRenderStateChanged()
        return attempt.response
    }

    fun bindAsync(
        host: AndroidPlayerHost,
        onComplete: (NativeResponse) -> Unit,
    ) {
        val response = bind(host)
        when {
            !response.ok -> onComplete(response)
            boundHost === host &&
                !nativeAttachPending &&
                !nativeDetachPending &&
                !nativeDetachRetryPending &&
                !lifecycleDetachPending ->
                onComplete(NativeResponse.success())
            else -> pendingBindCompletions += PendingViewCompletion(
                host,
                surfaceBindingGenerations.currentGeneration,
                onComplete,
            )
        }
    }

    fun unbind(expectedHost: AndroidPlayerHost? = null): NativeResponse {
        val host = boundHost
        if (host == null) {
            cancelSurfaceRecovery()
            if (disposeRequested) {
                finishDispose()
            }
            return NativeResponse.success()
        }
        if (expectedHost != null && host !== expectedHost) {
            return NativeResponse.success()
        }
        if (!unbindRequested) {
            advanceSurfaceBindingGeneration()
            completeBindCompletions(
                host,
                NativeResponse(false, -1, "Android surface bind was superseded by unbind", null),
                generation = null,
            )
        }
        unbindRequested = true
        stopHdrHeadroomObservation(publishUnknown = true)
        cancelSurfaceRecovery()
        if (!androidUnbindNeedsNewSurfaceDetach(lifecycleDetachPending)) {
            // The already queued lifecycle detach owns this unbind. Its real
            // callback will complete the unbind or report the native failure.
            return NativeResponse.success()
        }
        val response = detachNativeSurface(host)
        reportImmediateSurfaceAttempt(host, SurfaceAttempt("detachSurface", response))
        if (!response.ok) {
            startSurfaceRecovery(host, "detachSurface", response)
            return response
        }
        completeUnbind(host)
        return response
    }

    fun unbindAsync(
        expectedHost: AndroidPlayerHost,
        onComplete: (NativeResponse) -> Unit,
    ) {
        val host = boundHost
        if (host == null || host !== expectedHost) {
            onComplete(NativeResponse.success())
            return
        }
        val response = unbind(host)
        when {
            !response.ok -> onComplete(response)
            boundHost !== host ->
                onComplete(NativeResponse.success())
            else -> pendingUnbindCompletions += PendingViewCompletion(
                host,
                surfaceBindingGenerations.currentGeneration,
                onComplete,
            )
        }
    }

    fun suspendSurface(): NativeResponse {
        val host = boundHost ?: return NativeResponse.success()
        if (unbindRequested || disposeRequested) {
            return unbind(host)
        }
        unbindRequested = false
        stopHdrHeadroomObservation(publishUnknown = true)
        cancelSurfaceRecovery()
        val response = detachNativeSurface(host)
        reportImmediateSurfaceAttempt(host, SurfaceAttempt("detachSurface", response))
        if (!response.ok) {
            startSurfaceRecovery(host, "detachSurface", response)
        }
        plugin.onPlayerRenderStateChanged()
        return response
    }

    fun suspendSurfaceAsync() {
        val host = boundHost ?: return
        lifecycleSurfaceSuspended = true
        if (unbindRequested || disposeRequested) {
            unbind(host)
            return
        }
        unbindRequested = false
        // The detach queued below owns the lifecycle transition. Avoid a synchronous
        // setOutputHeadroom JNI call on the UI thread while the presenter may still be
        // finishing an in-flight frame.
        stopHdrHeadroomObservation(publishUnknown = false)
        cancelSurfaceRecovery()
        if (
            androidShouldRetainSurfaceDuringActivityStop(
                usesTextureView = textureView != null,
                outputSurfaceValid = outputSurface?.isValid == true,
            )
        ) {
            // TextureView will call onSurfaceTextureDestroyed if the buffer
            // queue is actually retired. Until then, retaining the native
            // surface avoids a detach/reattach cycle against the same queue.
            plugin.onPlayerRenderStateChanged()
            return
        }
        if (lifecycleDetachPending) {
            return
        }
        advanceSurfaceBindingGeneration(host)
        lifecycleDetachPending = true
        val posted = host.detachSurfaceAsync { result ->
            mainHandler.post {
                lifecycleDetachPending = false
                if (boundHost !== host || host.isDestroyed) {
                    if (host.isDestroyed) {
                        completeUnbindCompletions(
                            host,
                            NativeResponse(false, -1, "Erika player ${host.handle} was destroyed", null),
                        )
                    }
                    return@post
                }
                val response = result.getOrElse { error ->
                    surfaceOperationException(host, "detachSurface", error)
                }
                nativeDetachRetryPending = !response.ok && host.surfaceAttached
                releaseDeferredSurfacesIfIdle()
                if (response.ok) {
                    attachedDisplayId = null
                    attachedDisplayHdrSupported = null
                }
                plugin.reportSurfaceResponse(host, "detachSurface", response)
                if (!response.ok) {
                    completeUnbindCompletions(host, response)
                    failPendingBind(response)
                }
                if (androidDetachCompletesSupersededUnbind(
                        nativeDetachSucceeded = response.ok,
                        unbindRequested = unbindRequested,
                        disposeRequested = disposeRequested,
                    )
                ) {
                    completeUnbindCompletions(host, NativeResponse.success())
                }
                when {
                    !response.ok -> {
                        startSurfaceRecovery(host, "detachSurface", response)
                    }
                    unbindRequested || disposeRequested -> completeUnbind(host)
                    !lifecycleSurfaceSuspended && plugin.isActivityActive -> resumeSurface()
                }
                plugin.onPlayerRenderStateChanged()
            }
        }
        if (!posted) {
            lifecycleDetachPending = false
            val response = NativeResponse(
                false,
                -1,
                "Android presenter thread rejected lifecycle surface detach",
                null,
            )
            plugin.reportSurfaceResponse(host, "detachSurface", response)
            startSurfaceRecovery(host, "detachSurface", response)
        }
    }

    fun resumeSurface(): NativeResponse {
        val host = boundHost ?: return NativeResponse.success()
        lifecycleSurfaceSuspended = false
        if (lifecycleDetachPending) {
            return NativeResponse.success()
        }
        if (unbindRequested || disposeRequested) {
            return unbind(host)
        }
        unbindRequested = false
        cancelSurfaceRecovery()
        val attempt = attachIfReady(host)
        handleImmediateAttempt(host, attempt)
        refreshHdrHeadroomObservation()
        plugin.onPlayerRenderStateChanged()
        return attempt.response
    }

    fun setFlutterManagedVisibility(visible: Boolean, debugLabel: String?) {
        nativeView.visibility = if (visible) View.VISIBLE else View.INVISIBLE
        if (debugLabel != null) {
            nativeView.contentDescription = debugLabel
        }
    }

    fun setPlaybackKeepsScreenOn(enabled: Boolean) {
        nativeView.keepScreenOn = enabled
    }

    fun pixelWidth(): Int = surfacePixelWidth.takeIf { it > 0 } ?: nativeView.width

    fun pixelHeight(): Int = surfacePixelHeight.takeIf { it > 0 } ?: nativeView.height

    internal fun onPlayerDestroyed(host: AndroidPlayerHost) {
        hostsAwaitingNativeDestroy -= host
        val response = NativeResponse(
            false,
            -1,
            "Erika player ${host.handle} was destroyed",
            null,
        )
        if (pendingBind?.host === host) {
            failPendingBind(response)
        }
        if (boundHost !== host) {
            completeBindCompletions(host, response, generation = null)
            completeUnbindCompletions(host, response, generation = null)
            releaseDeferredSurfacesIfIdle()
            return
        }
        val deferredBind = takePendingBind()
        cancelSurfaceRecovery()
        nativeDetachRetryPending = false
        lifecycleDetachPending = false
        lifecycleSurfaceSuspended = false
        unbindRequested = false
        boundHost = null
        completeBindCompletions(host, response, generation = null)
        completeUnbindCompletions(host, response, generation = null)
        if (disposeRequested) {
            finishDispose()
        }
        releaseDeferredSurfacesIfIdle()
        resumePendingBind(deferredBind)
        plugin.onPlayerRenderStateChanged()
    }

    internal fun onPlayerDestroyQueued(host: AndroidPlayerHost) {
        hostsAwaitingNativeDestroy += host
    }

    override fun onSurfaceTextureAvailable(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        surfaceTexture.setDefaultBufferSize(max(1, width), max(1, height))
        onNativeSurfaceAvailable(
            Surface(surfaceTexture),
            width,
            height,
            ownsSurface = true,
            surfaceTexture = surfaceTexture,
        )
    }

    override fun onSurfaceTextureSizeChanged(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        surfaceTexture.setDefaultBufferSize(max(1, width), max(1, height))
        onNativeSurfaceSizeChanged(width, height)
    }

    override fun onSurfaceTextureDestroyed(surfaceTexture: SurfaceTexture): Boolean =
        onNativeSurfaceDestroyed(surfaceTexture)

    override fun onSurfaceTextureUpdated(surfaceTexture: SurfaceTexture) = Unit

    override fun surfaceCreated(holder: SurfaceHolder) {
        onNativeSurfaceAvailable(
            holder.surface,
            nativeView.width,
            nativeView.height,
            ownsSurface = false,
            surfaceTexture = null,
        )
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (outputSurface == null) {
            onNativeSurfaceAvailable(
                holder.surface,
                width,
                height,
                ownsSurface = false,
                surfaceTexture = null,
            )
        } else {
            onNativeSurfaceSizeChanged(width, height)
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        onNativeSurfaceDestroyed(null)
    }

    override fun surfaceRedrawNeeded(holder: SurfaceHolder) {
        boundHost?.requestRender()
        plugin.onPlayerRenderStateChanged()
    }

    private fun onNativeSurfaceAvailable(
        surface: Surface,
        width: Int,
        height: Int,
        ownsSurface: Boolean,
        surfaceTexture: SurfaceTexture?,
    ) {
        advanceSurfaceBindingGeneration(boundHost)
        cancelSurfaceRecovery()
        surfacePixelWidth = max(1, width)
        surfacePixelHeight = max(1, height)
        var detachResponse = NativeResponse.success()
        val host = boundHost
        if (host != null &&
            (host.surfaceAttached || nativeAttachPending || nativeDetachRetryPending)
        ) {
            detachResponse = detachNativeSurface(host)
            reportImmediateSurfaceAttempt(
                host,
                SurfaceAttempt("detachSurface", detachResponse),
            )
        }
        val previousSurfaceTexture = outputSurfaceTexture
        releaseSurface()
        if (previousSurfaceTexture != null && previousSurfaceTexture !== surfaceTexture) {
            deferOrReleaseSurfaceTexture(previousSurfaceTexture)
        }
        outputSurface = surface
        ownsOutputSurface = ownsSurface
        outputSurfaceTexture = surfaceTexture
        if (!detachResponse.ok) {
            if (host != null) {
                startSurfaceRecovery(host, "detachSurface", detachResponse)
            }
            plugin.onPlayerRenderStateChanged()
            return
        }
        if (host != null && (unbindRequested || disposeRequested)) {
            completeUnbind(host)
            return
        }
        host?.let { currentHost ->
            val attempt = attachIfReady(currentHost)
            handleImmediateAttempt(currentHost, attempt)
        }
        refreshHdrHeadroomObservation()
        plugin.onPlayerRenderStateChanged()
    }

    private fun onNativeSurfaceSizeChanged(width: Int, height: Int) {
        cancelSurfaceRecovery()
        surfacePixelWidth = max(1, width)
        surfacePixelHeight = max(1, height)
        val host = boundHost ?: return
        if (unbindRequested || disposeRequested) {
            val response = detachNativeSurface(host)
            reportImmediateSurfaceAttempt(host, SurfaceAttempt("detachSurface", response))
            if (response.ok) {
                completeUnbind(host)
            } else {
                startSurfaceRecovery(host, "detachSurface", response)
            }
            return
        }
        val metrics = surfaceMetrics(width, height)
        if (nativeDetachRetryPending) {
            val attempt = attachIfReady(host)
            handleImmediateAttempt(host, attempt)
        } else if (host.surfaceAttached) {
            handleImmediateAttempt(host, resizeNativeSurface(host, metrics))
        } else {
            val attempt = attachIfReady(host)
            handleImmediateAttempt(host, attempt)
        }
        refreshHdrHeadroomObservation()
        plugin.onPlayerRenderStateChanged()
    }

    private fun onNativeSurfaceDestroyed(surfaceTexture: SurfaceTexture?): Boolean {
        advanceSurfaceBindingGeneration(boundHost)
        stopHdrHeadroomObservation(publishUnknown = true)
        cancelSurfaceRecovery()
        val host = boundHost
        val response = host?.let { host ->
            val response = if (surfaceTexture != null) {
                detachNativeSurface(host)
            } else {
                host.detachSurfaceForSystemDestroy()
            }
            if (surfaceTexture == null) {
                plugin.reportSurfaceResponse(host, "detachSurface", response)
            } else {
                reportImmediateSurfaceAttempt(
                    host,
                    SurfaceAttempt("detachSurface", response),
                )
            }
            response
        } ?: NativeResponse.success()
        val decision = androidSurfaceDestroyDecision(response.ok)
        // A timed-out SurfaceView barrier remains queued on the serial presenter. Keep the
        // native attachment explicit as well: the serialized retry then observes the first
        // detach's final state before any replacement attach or unbind can complete.
        val retryNativeDetach = androidSurfaceDestroyNeedsRetry(
            nativeDetachSucceeded = response.ok,
            hostDestroying = host?.isDestroyed == true,
        )
        nativeDetachRetryPending = retryNativeDetach
        releaseSurface()
        if (outputSurfaceTexture === surfaceTexture) {
            outputSurfaceTexture = null
        }
        surfaceTexture?.let(::deferOrReleaseSurfaceTexture)
        surfacePixelWidth = 0
        surfacePixelHeight = 0
        if (host != null) {
            if (response.ok && (unbindRequested || disposeRequested)) {
                completeUnbind(host)
            } else if (retryNativeDetach) {
                startSurfaceRecovery(host, "detachSurface", response)
            }
        }
        plugin.onPlayerRenderStateChanged()
        return decision.releaseSurfaceTexture
    }

    private fun attachIfReady(host: AndroidPlayerHost): SurfaceAttempt {
        if (nativeDetachRetryPending) {
            val response = detachNativeSurface(host)
            if (!response.ok) {
                return SurfaceAttempt("detachSurface", response)
            }
        }
        if (nativeDetachPending) {
            return SurfaceAttempt("detachSurface", NativeResponse.success())
        }
        if (!plugin.isActivityActive || host.surfaceAttached) {
            return SurfaceAttempt("attachSurface", NativeResponse.success())
        }
        val surface = outputSurface
            ?: return SurfaceAttempt("attachSurface", NativeResponse.success())
        if (!surface.isValid) {
            return SurfaceAttempt("attachSurface", NativeResponse.success())
        }
        val display = nativeView.display
        if (useHdrSurface && display == null) {
            Log.i(
                TAG,
                "surfaceOutputCapability pending playerId=${host.handle} viewId=$viewId " +
                    "reason=display_not_attached_yet",
            )
            return SurfaceAttempt("attachSurface", NativeResponse.success())
        }
        val metrics = surfaceMetrics(pixelWidth(), pixelHeight())
        val displayHdrSupported = display?.let(::displaySupportsHdr) == true
        val directComposition = useHdrSurface && hybridComposition
        val outputCapability = androidOutputCapabilityDecision(
            extendedLinearRequested = useHdrSurface,
            sdkInt = Build.VERSION.SDK_INT,
            displayHdrSupported = displayHdrSupported,
            directComposition = directComposition,
        )
        Log.i(
            TAG,
            "surfaceOutputCapability playerId=${host.handle} viewId=$viewId " +
                "requestedExtendedLinear=$useHdrSurface " +
                "eligible=${outputCapability.extendedLinearEligible} " +
                "directComposition=$directComposition sdk=${Build.VERSION.SDK_INT} " +
                "requestedHeadroom=$requestedHdrHeadroom " +
                "fallbackReason=${androidOutputFallbackReasonLabel(outputCapability.fallbackReason)}" +
                "(${outputCapability.fallbackReason})",
        )
        if (nativeAttachPending) {
            return SurfaceAttempt("attachSurface", NativeResponse.success())
        }
        nativeAttachPending = true
        val bindingGeneration = surfaceBindingGenerations.currentGeneration
        val posted = host.attachSurfaceAsync(
            surface,
            metrics.width,
            metrics.height,
            metrics.scale,
            outputCapability.extendedLinearEligible,
            directComposition,
            requestedHdrHeadroom,
            outputCapability.fallbackReason,
        ) { result ->
            mainHandler.post {
                nativeAttachPending = false
                releaseDeferredSurfacesIfIdle()
                if (host.isDestroyed) {
                    completeBindCompletions(
                        host,
                        NativeResponse(false, -1, "Erika player ${host.handle} was destroyed", null),
                    )
                    return@post
                }
                val response = result.getOrElse { error ->
                    surfaceOperationException(host, "attachSurface", error)
                }
                val callbackIsCurrent = surfaceBindingGenerations.isCurrent(bindingGeneration) &&
                    boundHost === host && outputSurface === surface
                if (!callbackIsCurrent) {
                    handleStaleAttachCompletion(host, response)
                    return@post
                }
                if (response.ok) {
                    finishSurfaceRecovery(host, "attachSurface")
                    attachedDisplayId = display?.displayId
                    attachedDisplayHdrSupported = displayHdrSupported
                    val latestMetrics = surfaceMetrics(pixelWidth(), pixelHeight())
                    if (boundHost === host && latestMetrics != metrics) {
                        handleImmediateAttempt(host, resizeNativeSurface(host, latestMetrics))
                    }
                }
                plugin.reportSurfaceResponse(host, "attachSurface", response)
                completeBindCompletions(host, response, bindingGeneration)
                when {
                    !response.ok && boundHost === host ->
                        startSurfaceRecovery(host, "attachSurface", response)
                    boundHost === host && (unbindRequested || disposeRequested) ->
                        unbind(host)
                    boundHost === host && outputSurface !== surface -> {
                        val detach = detachNativeSurface(host)
                        if (!detach.ok) {
                            startSurfaceRecovery(host, "detachSurface", detach)
                        }
                    }
                }
                plugin.onPlayerRenderStateChanged()
            }
        }
        if (!posted) {
            nativeAttachPending = false
            return SurfaceAttempt(
                "attachSurface",
                NativeResponse(false, -1, "Android presenter thread is unavailable", null),
            )
        }
        return SurfaceAttempt("attachSurface", NativeResponse.success())
    }

    /**
     * A retired attach still changed native attachment state, but it no longer
     * owns any Dart completion or error reporting. Reconcile that physical
     * result into the newest binding instead of letting it pollute the request
     * that replaced it.
     */
    private fun handleStaleAttachCompletion(
        host: AndroidPlayerHost,
        response: NativeResponse,
    ) {
        Log.i(
            TAG,
            "surfaceAttachCompletionIgnored playerId=${host.handle} viewId=$viewId " +
                "status=${response.status} error=${response.error.orEmpty()}",
        )
        if (host.isDestroyed || boundHost !== host) {
            return
        }
        if (response.ok && host.surfaceAttached) {
            val detach = detachNativeSurface(host)
            handleImmediateAttempt(host, SurfaceAttempt("detachSurface", detach))
            return
        }
        if (!unbindRequested && !disposeRequested && !lifecycleSurfaceSuspended) {
            handleImmediateAttempt(host, attachIfReady(host))
        }
        plugin.onPlayerRenderStateChanged()
    }

    private fun displaySupportsHdr(display: Display): Boolean {
        // Display.isHdr is derived from getHdrCapabilities(), so it respects
        // user-disabled HDR output types. Display.Mode.supportedHdrTypes is
        // only the raw hardware list and can incorrectly keep FP16 output
        // eligible after the user disables every HDR type.
        return runCatching { display.isHdr }
            .onFailure { error ->
                Log.w(
                    TAG,
                    "display HDR capability query failed viewId=$viewId " +
                        "displayId=${display.displayId}",
                    error,
                )
            }
            .getOrDefault(false)
    }

    private fun refreshHdrHeadroomObservation() {
        if (
            !useHdrSurface ||
            Build.VERSION.SDK_INT < 34 ||
            disposed ||
            unbindRequested ||
            disposeRequested ||
            !plugin.isActivityActive ||
            !nativeView.isAttachedToWindow
        ) {
            stopHdrHeadroomObservation(publishUnknown = true)
            return
        }
        val host = boundHost ?: run {
            stopHdrHeadroomObservation(publishUnknown = false)
            return
        }
        val display = nativeView.display ?: run {
            stopHdrHeadroomObservation(publishUnknown = true)
            return
        }
        val displayHdrSupported = displaySupportsHdr(display)
        val displayCapabilityChanged = host.surfaceAttached &&
            (attachedDisplayId != display.displayId ||
                attachedDisplayHdrSupported != displayHdrSupported)
        if (displayCapabilityChanged) {
            Log.i(
                TAG,
                "surfaceDisplayChanged playerId=${host.handle} viewId=$viewId " +
                    "oldDisplayId=$attachedDisplayId newDisplayId=${display.displayId} " +
                    "oldHdr=$attachedDisplayHdrSupported newHdr=$displayHdrSupported " +
                    "action=detach_and_reattach",
            )
            stopHdrHeadroomObservation(publishUnknown = false)
            val detachResponse = detachNativeSurface(host)
            reportImmediateSurfaceAttempt(
                host,
                SurfaceAttempt("detachSurface", detachResponse),
            )
            if (!detachResponse.ok) {
                startSurfaceRecovery(host, "detachSurface", detachResponse)
                return
            }
            val attachAttempt = attachIfReady(host)
            handleImmediateAttempt(host, attachAttempt)
            if (!attachAttempt.response.ok || !host.surfaceAttached) {
                return
            }
        }

        if (observedHdrDisplay !== display) {
            stopHdrHeadroomObservation(publishUnknown = false)
            observedHdrDisplay = display
        }
        val ratioAvailable = runCatching { display.isHdrSdrRatioAvailable }
            .onFailure { error ->
                Log.w(
                    TAG,
                    "isHdrSdrRatioAvailable failed playerId=${host.handle} " +
                        "viewId=$viewId displayId=${display.displayId}",
                    error,
                )
            }
            .getOrDefault(false)
        if (ratioAvailable && !hdrRatioListenerRegistered) {
            runCatching {
                display.registerHdrSdrRatioChangedListener(
                    nativeView.context.mainExecutor,
                    hdrRatioListener,
                )
            }.onSuccess {
                hdrRatioListenerRegistered = true
            }.onFailure { error ->
                Log.w(
                    TAG,
                    "registerHdrSdrRatioChangedListener failed playerId=${host.handle} " +
                        "viewId=$viewId displayId=${display.displayId}",
                    error,
                )
            }
        } else if (!ratioAvailable && hdrRatioListenerRegistered) {
            stopHdrHeadroomObservation(publishUnknown = false)
            observedHdrDisplay = display
        }
        publishHdrHeadroom(host, display, ratioAvailable)
    }

    @TargetApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun publishHdrHeadroom(
        host: AndroidPlayerHost,
        display: Display,
        ratioAvailable: Boolean,
    ) {
        val ratio = if (ratioAvailable) {
            runCatching { display.hdrSdrRatio }.getOrElse { error ->
                Log.w(
                    TAG,
                    "getHdrSdrRatio failed playerId=${host.handle} viewId=$viewId " +
                        "displayId=${display.displayId}",
                    error,
                )
                Float.NaN
            }
        } else {
            Float.NaN
        }
        val state = androidHdrHeadroomState(ratioAvailable, ratio)
        if (lastPublishedHdrHeadroom == state) {
            return
        }
        val posted = host.setOutputHeadroomAsync(state.headroom, state.known) { result ->
            mainHandler.post {
                if (boundHost !== host || host.isDestroyed) {
                    return@post
                }
                val response = result.getOrElse { error ->
                    surfaceOperationException(host, "setOutputHeadroom", error)
                }
                if (!response.ok) {
                    plugin.reportSurfaceResponse(host, "setOutputHeadroom", response)
                } else {
                    lastPublishedHdrHeadroom = state
                }
                Log.i(
                    TAG,
                    "surfaceHeadroom playerId=${host.handle} viewId=$viewId " +
                        "displayId=${display.displayId} ratio=${state.headroom} " +
                        "known=${state.known} requested=$requestedHdrHeadroom " +
                        "status=${response.status} error=${response.error.orEmpty()}",
                )
            }
        }
        if (!posted) {
            plugin.reportSurfaceResponse(
                host,
                "setOutputHeadroom",
                NativeResponse(false, -1, "Android presenter thread is unavailable", null),
            )
        }
    }

    private fun stopHdrHeadroomObservation(publishUnknown: Boolean) {
        val display = observedHdrDisplay
        if (Build.VERSION.SDK_INT >= 34 && hdrRatioListenerRegistered && display != null) {
            runCatching { display.unregisterHdrSdrRatioChangedListener(hdrRatioListener) }
                .onFailure { error ->
                    Log.w(
                        TAG,
                        "unregisterHdrSdrRatioChangedListener failed viewId=$viewId " +
                            "displayId=${display.displayId}",
                        error,
                    )
                }
        }
        hdrRatioListenerRegistered = false
        observedHdrDisplay = null
        if (publishUnknown && useHdrSurface) {
            boundHost?.let { host ->
                val unknown = AndroidHdrHeadroomState(1f, false)
                if (lastPublishedHdrHeadroom == unknown) {
                    return@let
                }
                host.setOutputHeadroomAsync(unknown.headroom, unknown.known) { result ->
                    mainHandler.post {
                        if (boundHost !== host || host.isDestroyed) {
                            return@post
                        }
                        val response = result.getOrElse { error ->
                            surfaceOperationException(host, "setOutputHeadroom", error)
                        }
                        if (response.ok) {
                            lastPublishedHdrHeadroom = unknown
                        } else {
                            plugin.reportSurfaceResponse(host, "setOutputHeadroom", response)
                        }
                    }
                }
            }
        }
    }

    private fun detachNativeSurface(host: AndroidPlayerHost): NativeResponse {
        if ((!host.surfaceAttached && !nativeAttachPending) || host.isDestroyed) {
            return NativeResponse.success()
        }
        if (nativeDetachPending) {
            return NativeResponse.success()
        }
        nativeDetachPending = true
        val posted = host.detachSurfaceAsync { result ->
            mainHandler.post {
                nativeDetachPending = false
                val response = result.getOrElse { error ->
                    surfaceOperationException(host, "detachSurface", error)
                }
                nativeDetachRetryPending = !response.ok && host.surfaceAttached
                if (response.ok) {
                    finishSurfaceRecovery(host, "detachSurface")
                    attachedDisplayId = null
                    attachedDisplayHdrSupported = null
                }
                plugin.reportSurfaceResponse(host, "detachSurface", response)
                releaseDeferredSurfacesIfIdle()
                if (!response.ok) {
                    completeUnbindCompletions(host, response)
                    failPendingBind(response)
                }
                if (androidDetachCompletesSupersededUnbind(
                        nativeDetachSucceeded = response.ok,
                        unbindRequested = unbindRequested,
                        disposeRequested = disposeRequested,
                    )
                ) {
                    completeUnbindCompletions(host, NativeResponse.success())
                }
                if (boundHost === host && !host.isDestroyed) {
                    when {
                        !response.ok -> {
                            startSurfaceRecovery(host, "detachSurface", response)
                        }
                        unbindRequested || disposeRequested -> completeUnbind(host)
                        !lifecycleSurfaceSuspended -> {
                            val attempt = attachIfReady(host)
                            handleImmediateAttempt(host, attempt)
                            if (attempt.response.ok && !nativeAttachPending) {
                                completeBindCompletions(host, NativeResponse.success())
                            }
                        }
                    }
                }
                plugin.onPlayerRenderStateChanged()
            }
        }
        if (!posted) {
            nativeDetachPending = false
            return NativeResponse(
                false,
                -1,
                "Android presenter thread rejected surface detach",
                null,
            )
        }
        return NativeResponse.success()
    }

    private fun resizeNativeSurface(
        host: AndroidPlayerHost,
        metrics: AndroidSurfaceMetrics,
    ): SurfaceAttempt {
        if (host.isDestroyed) {
            pendingResizeRequest = null
            return SurfaceAttempt("resizeSurface", NativeResponse.success())
        }
        pendingResizeRequest = PendingSurfaceResize(
            host = host,
            surface = outputSurface,
            generation = surfaceBindingGenerations.currentGeneration,
            metrics = metrics,
        )
        if (nativeResizePending) {
            return SurfaceAttempt("resizeSurface", NativeResponse.success())
        }
        val next = pendingResizeRequest
            ?: return SurfaceAttempt("resizeSurface", NativeResponse.success())
        pendingResizeRequest = null
        nativeResizePending = true
        val posted = host.resizeSurfaceAsync(
            next.metrics.width,
            next.metrics.height,
            next.metrics.scale,
        ) { result ->
            mainHandler.post {
                nativeResizePending = false
                val response = if (host.isDestroyed) {
                    null
                } else {
                    result.getOrElse { error ->
                        surfaceOperationException(host, "resizeSurface", error)
                    }
                }
                val callbackIsCurrent = androidSurfaceCallbackIsCurrent(
                    callbackGeneration = next.generation,
                    currentGeneration = surfaceBindingGenerations.currentGeneration,
                    hostStillBound = boundHost === next.host,
                    surfaceStillCurrent = outputSurface === next.surface,
                )
                if (callbackIsCurrent && response != null) {
                    plugin.reportSurfaceResponse(host, "resizeSurface", response)
                    if (response.ok) {
                        finishSurfaceRecovery(host, "resizeSurface")
                    } else {
                        startSurfaceRecovery(host, "resizeSurface", response, next.metrics)
                    }
                }
                val pending = pendingResizeRequest
                if (pending != null) {
                    val pendingIsCurrent = androidSurfaceCallbackIsCurrent(
                        callbackGeneration = pending.generation,
                        currentGeneration = surfaceBindingGenerations.currentGeneration,
                        hostStillBound = boundHost === pending.host,
                        surfaceStillCurrent = outputSurface === pending.surface,
                    )
                    pendingResizeRequest = null
                    if (pendingIsCurrent) {
                        handleImmediateAttempt(
                            pending.host,
                            resizeNativeSurface(pending.host, pending.metrics),
                        )
                    }
                }
                plugin.onPlayerRenderStateChanged()
            }
        }
        if (!posted) {
            nativeResizePending = false
            return SurfaceAttempt(
                "resizeSurface",
                NativeResponse(false, -1, "Android presenter thread is unavailable", null),
            )
        }
        return SurfaceAttempt("resizeSurface", NativeResponse.success())
    }

    private fun surfaceOperationException(
        host: AndroidPlayerHost,
        operation: String,
        error: Throwable,
    ): NativeResponse {
        val message = error.message ?: "$operation threw without an error message"
        Log.e(
            TAG,
            "surfaceOperationException playerId=${host.handle} viewId=$viewId " +
                "operation=$operation error=$message",
            error,
        )
        return NativeResponse(false, -1, "$operation threw: $message", null)
    }

    private fun handleImmediateAttempt(host: AndroidPlayerHost, attempt: SurfaceAttempt) {
        if (!reportImmediateSurfaceAttempt(host, attempt)) {
            return
        }
        if (!attempt.response.ok) {
            startSurfaceRecovery(host, attempt.operation, attempt.response)
        }
    }

    /** Returns false while the native operation is merely queued/in flight. */
    private fun reportImmediateSurfaceAttempt(
        host: AndroidPlayerHost,
        attempt: SurfaceAttempt,
    ): Boolean {
        if (
            androidSurfaceOperationIsPending(
                operation = attempt.operation,
                nativeAttachPending = nativeAttachPending,
                nativeDetachPending = nativeDetachPending,
                nativeResizePending = nativeResizePending,
            )
        ) {
            return false
        }
        plugin.reportSurfaceResponse(host, attempt.operation, attempt.response)
        return true
    }

    private fun startSurfaceRecovery(
        host: AndroidPlayerHost,
        operation: String,
        response: NativeResponse,
        resizeMetrics: AndroidSurfaceMetrics? = null,
    ) {
        if (disposed || boundHost !== host) {
            return
        }
        val generation = surfaceRecoveryTokens.currentToken
        val retryAttempt = surfaceRecoveryAttempts.recordFailure(generation, operation)
        scheduleSurfaceRecovery(
            host = host,
            generation = generation,
            failedOperation = operation,
            failedResponse = response,
            retryAttempt = retryAttempt,
            resizeMetrics = resizeMetrics,
        )
    }

    private fun scheduleSurfaceRecovery(
        host: AndroidPlayerHost,
        generation: Long,
        failedOperation: String,
        failedResponse: NativeResponse,
        retryAttempt: Int,
        resizeMetrics: AndroidSurfaceMetrics?,
    ) {
        if (disposed || boundHost !== host || !surfaceRecoveryTokens.isCurrent(generation)) {
            return
        }
        val delayMillis = androidSurfaceRecoveryDelayMillis(retryAttempt)
        if (delayMillis == null) {
            surfaceRecoveryRunnable = null
            reportSurfaceRecoveryExhaustedOnce(
                host,
                generation,
                failedOperation,
                retryAttempt - 1,
                failedResponse,
            )
            return
        }

        Log.w(
            TAG,
            "surfaceRecoveryScheduled playerId=${host.handle} viewId=$viewId " +
                "operation=$failedOperation generation=$generation " +
                "retryAttempt=$retryAttempt delayMs=$delayMillis " +
                "status=${failedResponse.status} error=${failedResponse.error.orEmpty()}",
        )
        surfaceRecoveryRunnable?.let(mainHandler::removeCallbacks)
        val runnable = Runnable {
            if (disposed || boundHost !== host || !surfaceRecoveryTokens.isCurrent(generation)) {
                return@Runnable
            }
            surfaceRecoveryRunnable = null
            when (val result = performSurfaceRecovery(host, failedOperation, resizeMetrics)) {
                SurfaceRecoveryResult.Complete -> finishSurfaceRecovery(host, failedOperation)
                SurfaceRecoveryResult.Pending -> Log.d(
                    TAG,
                    "surfaceRecoveryDispatched playerId=${host.handle} viewId=$viewId " +
                        "operation=$failedOperation generation=$generation " +
                        "retryAttempt=$retryAttempt",
                )
                is SurfaceRecoveryResult.Failed -> startSurfaceRecovery(
                    host = host,
                    operation = result.attempt.operation,
                    response = result.attempt.response,
                    resizeMetrics = resizeMetrics.takeIf {
                        result.attempt.operation == "resizeSurface"
                    },
                )
            }
            plugin.onPlayerRenderStateChanged()
        }
        surfaceRecoveryRunnable = runnable
        if (!mainHandler.postDelayed(runnable, delayMillis)) {
            surfaceRecoveryRunnable = null
            reportSurfaceRecoveryExhaustedOnce(
                host,
                generation,
                failedOperation,
                retryAttempt - 1,
                failedResponse,
            )
        }
    }

    private fun reportSurfaceRecoveryExhaustedOnce(
        host: AndroidPlayerHost,
        generation: Long,
        failedOperation: String,
        retryAttempts: Int,
        failedResponse: NativeResponse,
    ) {
        if (!surfaceRecoveryAttempts.markExhaustionReported(generation, failedOperation)) {
            return
        }
        plugin.reportSurfaceRecoveryExhausted(
            host = host,
            viewId = viewId,
            operation = failedOperation,
            generation = generation,
            retryAttempts = retryAttempts,
            response = failedResponse,
        )
        retireHostAfterSurfaceRecoveryExhaustionIfNeeded(host, failedOperation)
        plugin.onPlayerRenderStateChanged()
    }

    private fun retireHostAfterSurfaceRecoveryExhaustionIfNeeded(
        host: AndroidPlayerHost,
        failedOperation: String,
    ) {
        if (
            androidSurfaceRecoveryExhaustionRequiresHostRetirement(
                failedOperation = failedOperation,
                nativeDetachRetryPending = nativeDetachRetryPending,
                unbindRequested = unbindRequested,
                disposeRequested = disposeRequested,
            )
        ) {
            plugin.retirePlayerAfterSurfaceRecoveryExhausted(host)
        }
    }

    private fun performSurfaceRecovery(
        host: AndroidPlayerHost,
        failedOperation: String,
        resizeMetrics: AndroidSurfaceMetrics?,
    ): SurfaceRecoveryResult {
        if (nativeAttachPending || nativeDetachPending || nativeResizePending) {
            return SurfaceRecoveryResult.Pending
        }
        if (nativeDetachRetryPending || unbindRequested || disposeRequested) {
            val detachResponse = detachNativeSurface(host)
            reportImmediateSurfaceAttempt(
                host,
                SurfaceAttempt("detachSurface", detachResponse),
            )
            if (!detachResponse.ok) {
                return SurfaceRecoveryResult.Failed(
                    SurfaceAttempt("detachSurface", detachResponse),
                )
            }
            if (nativeDetachPending) {
                return SurfaceRecoveryResult.Pending
            }
            if (unbindRequested || disposeRequested) {
                completeUnbind(host)
                return SurfaceRecoveryResult.Complete
            }
        }

        if (failedOperation == "resizeSurface" && host.surfaceAttached) {
            val attempt = resizeNativeSurface(
                host,
                resizeMetrics ?: surfaceMetrics(pixelWidth(), pixelHeight()),
            )
            reportImmediateSurfaceAttempt(host, attempt)
            if (!attempt.response.ok) {
                return SurfaceRecoveryResult.Failed(attempt)
            }
            return if (nativeResizePending) {
                SurfaceRecoveryResult.Pending
            } else {
                SurfaceRecoveryResult.Complete
            }
        }

        val attachAttempt = attachIfReady(host)
        reportImmediateSurfaceAttempt(host, attachAttempt)
        if (!attachAttempt.response.ok) {
            return SurfaceRecoveryResult.Failed(attachAttempt)
        }
        return if (nativeAttachPending) {
            SurfaceRecoveryResult.Pending
        } else {
            SurfaceRecoveryResult.Complete
        }
    }

    private fun finishSurfaceRecovery(host: AndroidPlayerHost, operation: String) {
        val generation = surfaceRecoveryTokens.currentToken
        if (!surfaceRecoveryAttempts.complete(generation, operation)) {
            return
        }
        surfaceRecoveryRunnable?.let(mainHandler::removeCallbacks)
        surfaceRecoveryRunnable = null
        Log.i(
            TAG,
            "surfaceRecoverySucceeded playerId=${host.handle} viewId=$viewId " +
                "operation=$operation generation=$generation",
        )
        if (
            androidShouldRefreshHdrHeadroomAfterRecovery(
                hostStillBound = boundHost === host,
                surfaceAttached = host.surfaceAttached,
                disposed = disposed,
                disposeRequested = disposeRequested,
                unbindRequested = unbindRequested,
            )
        ) {
            refreshHdrHeadroomObservation()
        }
    }

    private fun completeUnbind(host: AndroidPlayerHost) {
        if (nativeAttachPending || nativeDetachPending) {
            return
        }
        val deferredBind = takePendingBind()
        stopHdrHeadroomObservation(publishUnknown = false)
        cancelSurfaceRecovery()
        nativeDetachRetryPending = false
        if (host.attachedView === this) {
            host.attachedView = null
        }
        if (boundHost === host) {
            boundHost = null
        }
        lastPublishedHdrHeadroom = null
        unbindRequested = false
        lifecycleSurfaceSuspended = false
        completeUnbindCompletions(host, NativeResponse.success())
        if (disposeRequested) {
            finishDispose()
        }
        resumePendingBind(deferredBind)
        plugin.onPlayerRenderStateChanged()
    }

    private fun queuePendingBind(host: AndroidPlayerHost, targetView: ErikaAndroidVideoView) {
        pendingBind = PendingViewBind(host, targetView)
        Log.w(
            TAG,
            "surfaceBindDeferred playerId=${host.handle} sourceViewId=$viewId " +
                "targetViewId=${targetView.viewId} reason=native_detach_recovery",
        )
    }

    private fun clearPendingBind() {
        failPendingBind(
            NativeResponse(false, -1, "Android surface bind was superseded", null),
        )
    }

    private fun failPendingBind(response: NativeResponse) {
        val deferred = takePendingBind() ?: return
        deferred.targetView.completeBindCompletions(deferred.host, response)
    }

    private fun takePendingBind(): PendingViewBind? {
        val deferredBind = pendingBind
        pendingBind = null
        return deferredBind
    }

    private fun resumePendingBind(deferredBind: PendingViewBind?) {
        val pending = deferredBind ?: return
        val targetView = pending.targetView
        val targetAcceptsHost = targetView.boundHost == null ||
            targetView.boundHost === pending.host
        val hostAcceptsTarget = pending.host.attachedView == null ||
            pending.host.attachedView === targetView
        if (
            !androidShouldResumePendingViewBind(
                hostDestroyed = pending.host.isDestroyed,
                targetDisposed = targetView.disposed,
                targetDisposeRequested = targetView.disposeRequested,
                targetAcceptsHost = targetAcceptsHost,
                hostAcceptsTarget = hostAcceptsTarget,
            )
        ) {
            Log.i(
                TAG,
                "surfaceBindDeferredCancelled playerId=${pending.host.handle} " +
                    "sourceViewId=$viewId targetViewId=${targetView.viewId} " +
                    "hostDestroyed=${pending.host.isDestroyed} " +
                    "targetDisposed=${targetView.disposed} " +
                    "targetDisposeRequested=${targetView.disposeRequested} " +
                    "targetAcceptsHost=$targetAcceptsHost " +
                    "hostAcceptsTarget=$hostAcceptsTarget",
            )
            targetView.completeBindCompletions(
                pending.host,
                NativeResponse(false, -1, "Deferred surface bind was cancelled", null),
            )
            return
        }
        Log.i(
            TAG,
            "surfaceBindDeferredResume playerId=${pending.host.handle} " +
                "sourceViewId=$viewId targetViewId=${targetView.viewId}",
        )
        runCatching { targetView.bind(pending.host) }
            .onSuccess { response ->
                if (!response.ok) {
                    targetView.completeBindCompletions(pending.host, response)
                    Log.w(
                        TAG,
                        "surfaceBindDeferredStillPending playerId=${pending.host.handle} " +
                            "sourceViewId=$viewId targetViewId=${targetView.viewId} " +
                            "status=${response.status} error=${response.error.orEmpty()}",
                    )
                } else if (!targetView.nativeAttachPending) {
                    targetView.completeBindCompletions(
                        pending.host,
                        NativeResponse.success(),
                    )
                }
            }
            .onFailure { error ->
                targetView.completeBindCompletions(
                    pending.host,
                    NativeResponse(false, -1, error.message ?: "Deferred surface bind threw", null),
                )
                Log.e(
                    TAG,
                    "surfaceBindDeferredFailed playerId=${pending.host.handle} " +
                        "sourceViewId=$viewId targetViewId=${targetView.viewId}",
                    error,
                )
            }
    }

    private fun completeBindCompletions(
        host: AndroidPlayerHost,
        response: NativeResponse,
        generation: Long? = surfaceBindingGenerations.currentGeneration,
    ) {
        completeViewCompletions(pendingBindCompletions, host, response, generation)
    }

    private fun completeUnbindCompletions(
        host: AndroidPlayerHost,
        response: NativeResponse,
        generation: Long? = null,
    ) {
        completeViewCompletions(pendingUnbindCompletions, host, response, generation)
    }

    private fun completeViewCompletions(
        completions: MutableList<PendingViewCompletion>,
        host: AndroidPlayerHost,
        response: NativeResponse,
        generation: Long?,
    ) {
        val callbacks = mutableListOf<(NativeResponse) -> Unit>()
        val iterator = completions.iterator()
        while (iterator.hasNext()) {
            val completion = iterator.next()
            if (completion.host === host && androidSurfaceCompletionMatchesGeneration(
                    completionGeneration = completion.generation,
                    callbackGeneration = generation,
                )
            ) {
                iterator.remove()
                callbacks += completion.onComplete
            }
        }
        callbacks.forEach { callback -> callback(response) }
    }

    private fun advanceSurfaceBindingGeneration(
        migratePendingBindForHost: AndroidPlayerHost? = null,
    ): Long {
        val generation = surfaceBindingGenerations.advance()
        pendingResizeRequest = pendingResizeRequest
            ?.takeIf { request -> request.generation == generation }
        if (migratePendingBindForHost != null) {
            pendingBindCompletions
                .filter { completion -> completion.host === migratePendingBindForHost }
                .forEach { completion -> completion.generation = generation }
        }
        return generation
    }

    private fun failAllViewCompletions(message: String) {
        val response = NativeResponse(false, -1, message, null)
        val callbacks = (pendingBindCompletions + pendingUnbindCompletions)
            .map(PendingViewCompletion::onComplete)
        pendingBindCompletions.clear()
        pendingUnbindCompletions.clear()
        callbacks.forEach { callback -> callback(response) }
    }

    private fun cancelSurfaceRecovery() {
        surfaceRecoveryTokens.invalidate()
        surfaceRecoveryAttempts.reset()
        surfaceRecoveryRunnable?.let(mainHandler::removeCallbacks)
        surfaceRecoveryRunnable = null
    }

    private fun surfaceMetrics(pixelWidth: Int, pixelHeight: Int): AndroidSurfaceMetrics {
        // Surface callbacks already report exact physical pixels. Density is
        // carried separately so native logical UI content (danmaku/subtitles)
        // scales like Flutter without resizing the wgpu swapchain.
        return resolveAndroidSurfaceMetrics(
            pixelWidth = pixelWidth,
            pixelHeight = pixelHeight,
            density = nativeView.resources.displayMetrics.density.toDouble(),
        )
    }

    private fun releaseSurface() {
        if (ownsOutputSurface) {
            outputSurface?.let { surface ->
                if (surfaceReleaseMustWait()) {
                    deferredSurfaceReleases += surface
                } else {
                    surface.release()
                }
            }
        }
        outputSurface = null
        ownsOutputSurface = false
    }

    private fun releaseDeferredSurfacesIfIdle() {
        if (surfaceReleaseMustWait()) {
            return
        }
        deferredSurfaceReleases.forEach(Surface::release)
        deferredSurfaceReleases.clear()
        deferredSurfaceTextureReleases.forEach(SurfaceTexture::release)
        deferredSurfaceTextureReleases.clear()
    }

    private fun deferOrReleaseSurfaceTexture(surfaceTexture: SurfaceTexture) {
        if (surfaceReleaseMustWait()) {
            if (deferredSurfaceTextureReleases.none { it === surfaceTexture }) {
                deferredSurfaceTextureReleases += surfaceTexture
            }
        } else {
            surfaceTexture.release()
        }
    }

    private fun surfaceReleaseMustWait(): Boolean =
        nativeAttachPending ||
            nativeDetachPending ||
            lifecycleDetachPending ||
            nativeDetachRetryPending ||
            boundHost?.surfaceAttached == true ||
            boundHost?.isNativeDestroyPending == true ||
            hostsAwaitingNativeDestroy.isNotEmpty()

    private data class SurfaceAttempt(
        val operation: String,
        val response: NativeResponse,
    )

    private sealed interface SurfaceRecoveryResult {
        data object Complete : SurfaceRecoveryResult
        data object Pending : SurfaceRecoveryResult
        data class Failed(val attempt: SurfaceAttempt) : SurfaceRecoveryResult
    }

    private data class PendingViewBind(
        val host: AndroidPlayerHost,
        val targetView: ErikaAndroidVideoView,
    )

    private data class PendingViewCompletion(
        val host: AndroidPlayerHost,
        var generation: Long,
        val onComplete: (NativeResponse) -> Unit,
    )

    private data class PendingSurfaceResize(
        val host: AndroidPlayerHost,
        val surface: Surface?,
        val generation: Long,
        val metrics: AndroidSurfaceMetrics,
    )

    private companion object {
        const val TAG = "ErikaAndroidVideoView"
    }
}
