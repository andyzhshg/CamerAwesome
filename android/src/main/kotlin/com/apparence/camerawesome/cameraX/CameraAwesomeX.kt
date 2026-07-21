package com.apparence.camerawesome.cameraX

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.*
import android.hardware.camera2.CameraCharacteristics
import android.location.Location
import android.os.*
import android.util.Log
import android.util.Rational
import android.util.Size
import androidx.camera.camera2.Camera2Config
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.VideoRecordEvent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.util.Consumer
import androidx.exifinterface.media.ExifInterface
import com.apparence.camerawesome.*
import com.apparence.camerawesome.buttons.PhysicalButtonMessageHandler
import com.apparence.camerawesome.buttons.PhysicalButtonsHandler
import com.apparence.camerawesome.buttons.PlayerService
import com.apparence.camerawesome.models.FlashMode
import com.apparence.camerawesome.sensors.SensorOrientationListener
import com.apparence.camerawesome.utils.isMultiCamSupported
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import io.reactivex.rxjava3.disposables.Disposable
import io.reactivex.rxjava3.subjects.BehaviorSubject
import kotlinx.coroutines.*
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.math.roundToInt


enum class CaptureModes {
    PHOTO, VIDEO, PREVIEW, ANALYSIS_ONLY,
}

internal class B2NativeSpikeRunState {
    val setupCount = AtomicInteger(0)
    val bindCount = AtomicInteger(0)
    val frameSequence = AtomicLong(0)
    val lastFrameUs = AtomicLong(-1)
    val sampledScenarioRevisions = ConcurrentHashMap.newKeySet<String>()
    val paused = AtomicBoolean(false)
    val resumeStartedUs = AtomicLong(-1)
}

internal data class B2NativeSpikeContext(
    val runId: String,
    val scenarioId: String,
    val deviceClass: String,
    val osVersion: String,
    val expectedLens: String,
    val contextRevision: Int,
    val runState: B2NativeSpikeRunState,
)

internal object B2NativeSpikeTelemetry {
    const val CHANNEL_NAME = "daily_cam/b2_native_spike"
    const val METHOD_SET_CONTEXT = "setContext"
    const val METHOD_FINISH_CONTEXT = "finishContext"
    const val METHOD_NATIVE_EVENT = "nativeEvent"
    private val contextReference = AtomicReference<B2NativeSpikeContext?>(null)
    private val channelReference = AtomicReference<MethodChannel?>(null)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val deliveryLock = Any()
    private var pendingDeliveries = 0
    private var pendingFinish: (() -> Unit)? = null

    fun attachChannel(channel: MethodChannel) {
        channelReference.set(channel)
    }

    fun detachChannel(channel: MethodChannel?) {
        channelReference.compareAndSet(channel, null)
    }

    fun snapshot(): B2NativeSpikeContext? = contextReference.get()

    @Synchronized
    fun setContext(arguments: Any?): Int {
        val map = arguments as? Map<*, *>
            ?: throw IllegalArgumentException("setContext requires a context map")
        val runId = requiredString(map, "runId")
        val scenarioId = requiredString(map, "scenarioId")
        val deviceClass = requiredString(map, "deviceClass")
        val osVersion = requiredString(map, "osVersion")
        val expectedLens = requiredString(map, "expectedLens")
        val revision = (map["contextRevision"] as? Number)?.toInt()
            ?: throw IllegalArgumentException("contextRevision must be an int")
        require(deviceClass == "phone" || deviceClass == "large") {
            "deviceClass must be phone or large"
        }
        require(expectedLens == "front" || expectedLens == "back") {
            "expectedLens must be front or back"
        }

        val current = contextReference.get()
        val runState = if (current == null || current.runId != runId) {
            require(revision == 1) { "a new run must start at contextRevision 1" }
            B2NativeSpikeRunState()
        } else {
            require(revision == current.contextRevision + 1) {
                "contextRevision must increase by exactly one"
            }
            require(deviceClass == current.deviceClass && osVersion == current.osVersion) {
                "run identity cannot change within a run"
            }
            current.runState
        }

        contextReference.set(
            B2NativeSpikeContext(
                runId = runId,
                scenarioId = scenarioId,
                deviceClass = deviceClass,
                osVersion = osVersion,
                expectedLens = expectedLens,
                contextRevision = revision,
                runState = runState,
            )
        )
        return revision
    }

    fun clearContext() {
        contextReference.set(null)
    }

    fun finishContext(arguments: Any?, onDrained: (Map<String, Any?>) -> Unit) {
        val map = arguments as? Map<*, *>
            ?: throw IllegalArgumentException("finishContext requires a map")
        val runId = requiredString(map, "runId")
        var finishNow = false
        synchronized(deliveryLock) {
            val current = contextReference.get()
                ?: throw IllegalArgumentException("finishContext has no active context")
            require(current.runId == runId) { "finishContext runId mismatch" }
            require(pendingFinish == null) { "finishContext is already pending" }
            contextReference.set(null)
            val finish = { onDrained(mapOf("runId" to runId)) }
            if (pendingDeliveries == 0) {
                finishNow = true
            } else {
                pendingFinish = finish
            }
        }
        if (finishNow) mainHandler.post { onDrained(mapOf("runId" to runId)) }
    }

    private fun completeDelivery() {
        var finish: (() -> Unit)? = null
        synchronized(deliveryLock) {
            pendingDeliveries -= 1
            check(pendingDeliveries >= 0) { "native spike delivery count underflow" }
            if (pendingDeliveries == 0) {
                finish = pendingFinish
                pendingFinish = null
            }
        }
        finish?.invoke()
    }

    fun emit(
        context: B2NativeSpikeContext?,
        event: String,
        eventDetail: String? = null,
        nativeSessionId: String? = null,
        lens: String? = null,
        nativeApplied: Boolean? = null,
        analysisImage: Map<String, Any?>? = null,
        frameGapMs: Double? = null,
        resumeToFirstFrameMs: Double? = null,
        monotonicUs: Long = elapsedRealtimeUs(),
    ) {
        if (context == null) return
        val state = context.runState
        val values = linkedMapOf<String, Any?>(
            "schemaVersion" to 2,
            "runId" to context.runId,
            "scenarioId" to context.scenarioId,
            "contextRevision" to context.contextRevision,
            "platform" to "android",
            "deviceClass" to context.deviceClass,
            "osVersion" to context.osVersion,
            "expectedLens" to context.expectedLens,
            "lens" to lens,
            "event" to event,
            "eventDetail" to eventDetail,
            "clockDomain" to "android_elapsed_realtime",
            "monotonicUs" to monotonicUs,
            "dartCameraContextId" to null,
            "dartSessionId" to null,
            "nativeSessionId" to nativeSessionId,
            "nativeApplied" to nativeApplied,
            "previewFit" to null,
            "previewDisplayScale" to null,
            "viewportLogicalPx" to null,
            "analysisPreview" to null,
            "analysisImage" to analysisImage,
            "setupCount" to state.setupCount.get(),
            "bindCount" to state.bindCount.get(),
            "frameGapMs" to frameGapMs,
            "resumeToFirstFrameMs" to resumeToFirstFrameMs,
            "blackFrameObserved" to null,
        )
        synchronized(deliveryLock) {
            val active = contextReference.get()
            if (active?.runId != context.runId) return
            val channel = channelReference.get() ?: return
            pendingDeliveries += 1
            mainHandler.post {
                channel.invokeMethod(METHOD_NATIVE_EVENT, values, object : MethodChannel.Result {
                    override fun success(result: Any?) = completeDelivery()
                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                        completeDelivery()
                    override fun notImplemented() = completeDelivery()
                })
            }
        }
    }

    fun recordSetupApplied(
        context: B2NativeSpikeContext?,
        nativeSessionId: String?,
    ) {
        if (context == null) return
        context.runState.setupCount.incrementAndGet()
        emit(
            context = context,
            event = "native_setup",
            eventDetail = "camera_state_committed",
            nativeSessionId = nativeSessionId,
            lens = null,
            nativeApplied = true,
        )
    }

    fun recordBindApplied(
        context: B2NativeSpikeContext?,
        nativeSessionId: String?,
        lens: String?,
    ) {
        if (context == null) return
        context.runState.bindCount.incrementAndGet()
        emit(
            context = context,
            event = "native_bind",
            eventDetail = "bind_to_lifecycle_committed",
            nativeSessionId = nativeSessionId,
            lens = lens,
            nativeApplied = true,
        )
        emit(
            context = context,
            event = "native_start",
            eventDetail = "bound_lifecycle_started",
            nativeSessionId = nativeSessionId,
            lens = lens,
            nativeApplied = true,
        )
    }

    fun recordPause(
        context: B2NativeSpikeContext?,
        nativeSessionId: String?,
        lens: String?,
    ) {
        if (context == null) return
        context.runState.paused.set(true)
        emit(
            context = context,
            event = "lifecycle",
            eventDetail = "pause",
            nativeSessionId = nativeSessionId,
            lens = lens,
            nativeApplied = false,
        )
    }

    fun recordResume(
        context: B2NativeSpikeContext?,
        nativeSessionId: String?,
        lens: String?,
    ) {
        if (context == null || !context.runState.paused.compareAndSet(true, false)) return
        val nowUs = elapsedRealtimeUs()
        context.runState.resumeStartedUs.set(nowUs)
        emit(
            context = context,
            event = "lifecycle",
            eventDetail = "resume",
            nativeSessionId = nativeSessionId,
            lens = lens,
            nativeApplied = false,
            monotonicUs = nowUs,
        )
    }

    fun recordAnalysisFrame(
        context: B2NativeSpikeContext?,
        nativeSessionId: String?,
        lens: String?,
        latestNativeOrientation: String,
        format: String,
        width: Int,
        height: Int,
        cropLeft: Int?,
        cropTop: Int?,
        cropRight: Int?,
        cropBottom: Int?,
        callbackRotationDegrees: Int,
        samplePtsUs: Long,
    ) {
        if (context == null) return
        val state = context.runState
        val nowUs = elapsedRealtimeUs()
        val sequence = state.frameSequence.incrementAndGet()
        val previousUs = state.lastFrameUs.getAndSet(nowUs)
        val frameGapMs = if (previousUs >= 0) (nowUs - previousUs) / 1000.0 else null
        val scenarioKey = "${context.runId}:${context.contextRevision}"
        val isScenarioFirst = state.sampledScenarioRevisions.add(scenarioKey)
        val resumeStartedUs = state.resumeStartedUs.getAndSet(-1)
        val isResumeFirst = resumeStartedUs >= 0
        val isPeriodic = sequence % 30L == 0L
        val isGap = frameGapMs != null && frameGapMs > 1000.0
        if (!isScenarioFirst && !isResumeFirst && !isPeriodic && !isGap) return

        val analysisImage = linkedMapOf<String, Any?>(
            "format" to format,
            "width" to width,
            "height" to height,
            "sourceWidth" to width,
            "sourceHeight" to height,
            "cropLeft" to cropLeft,
            "cropTop" to cropTop,
            "cropRight" to cropRight,
            "cropBottom" to cropBottom,
            "rotation" to "rotation${callbackRotationDegrees}deg",
            "frameSequence" to sequence,
            "samplePtsUs" to samplePtsUs,
            "latestNativeOrientation" to latestNativeOrientation,
            "callbackRawOrientation" to null,
            "callbackRotationDegrees" to callbackRotationDegrees,
            "softwareRotated" to false,
        )
        emit(
            context = context,
            event = "analysis_frame",
            eventDetail = when {
                isResumeFirst -> "post_resume_first"
                isScenarioFirst -> "scenario_first"
                isGap -> "gap_over_1000ms"
                else -> "periodic_30"
            },
            nativeSessionId = nativeSessionId,
            lens = lens,
            nativeApplied = true,
            analysisImage = analysisImage,
            frameGapMs = frameGapMs,
            resumeToFirstFrameMs = if (isResumeFirst) {
                (nowUs - resumeStartedUs) / 1000.0
            } else {
                null
            },
            monotonicUs = nowUs,
        )
    }

    private fun requiredString(map: Map<*, *>, key: String): String {
        val value = map[key] as? String
        require(!value.isNullOrBlank()) { "$key must be a non-empty string" }
        return value
    }

    private fun elapsedRealtimeUs(): Long = SystemClock.elapsedRealtimeNanos() / 1000L

}

class CameraAwesomeX : CameraInterface, FlutterPlugin, ActivityAware {
    private lateinit var physicalButtonHandler: PhysicalButtonsHandler
    private var binding: FlutterPluginBinding? = null
    private var textureRegistry: TextureRegistry? = null
    private var activity: Activity? = null
    private lateinit var imageStreamChannel: EventChannel
    private lateinit var orientationStreamChannel: EventChannel
    private var nativeSpikeChannel: MethodChannel? = null
    private var orientationStreamListener: OrientationStreamListener? = null
    private val sensorOrientationListener: SensorOrientationListener = SensorOrientationListener()

    private lateinit var cameraState: CameraXState
    private val cameraPermissions = CameraPermissions()
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private var exifPreferences = ExifPreferences(false)
    private var cancellationTokenSource = CancellationTokenSource()
    private var lastRecordedVideos: List<BehaviorSubject<Boolean>>? = null
    private var lastRecordedVideoSubscriptions: MutableList<Disposable>? = null
    private var colorMatrix: List<Double>? = null

    private val noneFilter: List<Double> = listOf(
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0
    )

    @SuppressLint("UnsafeOptInUsageError")
    fun configureCameraXLogs() {
        try {
            ProcessCameraProvider.configureInstance(
                CameraXConfig.Builder.fromConfig(Camera2Config.defaultConfig())
                    .setMinimumLoggingLevel(Log.ERROR).build()
            )
        } catch (e: IllegalStateException) {
            // Ignore if trying to configure CameraX more than once
        }
    }

    private fun getCameraProvider(): ProcessCameraProvider {
        configureCameraXLogs()
        val future = ProcessCameraProvider.getInstance(
            activity!!
        )
        return future.get()
    }


    @SuppressLint("RestrictedApi")
    override fun setupCamera(
        sensors: List<PigeonSensor>,
        aspectRatio: String,
        zoom: Double,
        mirrorFrontCamera: Boolean,
        enablePhysicalButton: Boolean,
        flashMode: String,
        captureMode: String,
        enableImageStream: Boolean,
        exifPreferences: ExifPreferences,
        videoOptions: VideoOptions?,
        callback: (Result<Boolean>) -> Unit
    ) {
        val spikeContext = B2NativeSpikeTelemetry.snapshot()
        B2NativeSpikeTelemetry.emit(
            context = spikeContext,
            event = "native_setup",
            eventDetail = "setup_camera_request",
            nativeApplied = false,
        )
        if (enablePhysicalButton) {
            val serviceIntent = Intent(activity!!, PlayerService::class.java)
            serviceIntent.putExtra(
                PhysicalButtonsHandler.BROADCAST_VOLUME_BUTTONS,
                Messenger(PhysicalButtonMessageHandler(physicalButtonHandler))
            )
            activity!!.startService(serviceIntent)
        } else {
            activity!!.stopService(Intent(activity!!, PlayerService::class.java))
        }

        val cameraProvider = getCameraProvider()

        val mode = CaptureModes.valueOf(captureMode)
        cameraState = CameraXState(cameraProvider = cameraProvider,
            textureEntries = sensors.mapIndexed { index: Int, pigeonSensor: PigeonSensor ->
                (pigeonSensor.deviceId
                    ?: index.toString()) to textureRegistry!!.createSurfaceTexture()
            }.toMap(),
            sensors = sensors,
            mirrorFrontCamera = mirrorFrontCamera,
            currentCaptureMode = mode,
            enableImageStream = enableImageStream,
            videoOptions = videoOptions?.android,
            videoRecordingQuality = videoOptions?.quality,
            onStreamReady = { state -> state.updateLifecycle(activity!!) }).apply {
            this.updateAspectRatio(aspectRatio)
            this.flashMode = FlashMode.valueOf(flashMode)
            this.enableAudioRecording = videoOptions?.enableAudio ?: true
        }
        B2NativeSpikeTelemetry.recordSetupApplied(
            context = spikeContext,
            nativeSessionId = cameraState.nativeSessionIdForSpike(),
        )
        this.exifPreferences = exifPreferences
        orientationStreamListener =
            OrientationStreamListener(activity!!, listOf(sensorOrientationListener, cameraState))
        imageStreamChannel.setStreamHandler(cameraState)
        if (mode != CaptureModes.ANALYSIS_ONLY) {
            cameraState.updateLifecycle(activity!!)
            // Zoom should be set after updateLifeCycle
            if (zoom > 0) {
                // TODO Find a better way to set initial zoom than using a postDelayed
                Handler(Looper.getMainLooper()).postDelayed({
                    cameraState.setZoom(zoom.toFloat())
                }, 200)
            }
        }

        callback(Result.success(true))
    }

    override fun checkPermissions(permissions: List<String>): List<String> {
        throw Exception("Not implemented on Android")
    }

    override fun setupImageAnalysisStream(
        format: String, width: Long, maxFramesPerSecond: Double?, autoStart: Boolean
    ) {
        cameraState.apply {
            val state = this
            val spikeContext = B2NativeSpikeTelemetry.snapshot()
            B2NativeSpikeTelemetry.emit(
                context = spikeContext,
                event = "native_setup",
                eventDetail = "analysis_stream_config_request",
                nativeSessionId = state.nativeSessionIdForSpike(),
                lens = state.actualLensForSpike(),
                nativeApplied = false,
            )
            try {
                imageAnalysisBuilder = ImageAnalysisBuilder.configure(
                    aspectRatio ?: AspectRatio.RATIO_4_3,
                    when (format.uppercase()) {
                        "YUV_420" -> OutputImageFormat.YUV_420_888
                        "NV21" -> OutputImageFormat.NV21
                        "JPEG" -> OutputImageFormat.JPEG
                        "BGRA8888" -> OutputImageFormat.RGBA_8888
                        else -> OutputImageFormat.NV21
                    },
                    executor(activity!!), width,
                    maxFramesPerSecond = maxFramesPerSecond,
                    nativeSessionIdProvider = state::nativeSessionIdForSpike,
                    actualLensProvider = state::actualLensForSpike,
                    latestNativeOrientationProvider = state::latestNativeOrientationForSpike,
                )
                enableImageStream = autoStart
                updateLifecycle(activity!!)
            } catch (e: Exception) {
                Log.e(CamerawesomePlugin.TAG, "error while enable image analysis", e)
            }
        }

    }

    override fun setExifPreferences(
        exifPreferences: ExifPreferences, callback: (Result<Boolean>) -> Unit
    ) {
        if (exifPreferences.saveGPSLocation) {
            val permissions = listOf(
                Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION
            )
            CoroutineScope(Dispatchers.Main).launch {
                if (cameraPermissions.hasPermission(activity!!, permissions)) {
                    this@CameraAwesomeX.exifPreferences = exifPreferences
                    callback(Result.success(true))
                } else {
                    cameraPermissions.requestPermissions(
                        activity!!,
                        permissions,
                        CameraPermissions.PERMISSION_GEOLOC,
                    ) { grantedPermissions ->
                        if (grantedPermissions.isNotEmpty()) {
                            this@CameraAwesomeX.exifPreferences = exifPreferences
                        }
                        callback(Result.success(grantedPermissions.isNotEmpty()))
                    }
                }
            }
        } else {
            this.exifPreferences = exifPreferences
            callback(Result.success(true))
        }
    }

    override fun setFilter(matrix: List<Double>) {
        colorMatrix = matrix
    }

    override fun isVideoRecordingAndImageAnalysisSupported(
        sensor: PigeonSensorPosition, callback: (Result<Boolean>) -> Unit
    ) {
        val cameraSelector =
            if (sensor == PigeonSensorPosition.BACK) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val cameraProvider = ProcessCameraProvider.getInstance(
                activity!!
            ).get()
            callback(
                Result.success(
                    CameraCapabilities.getCameraLevel(
                        cameraSelector, cameraProvider
                    ) == CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3
                )
            )
        } else {
            callback(Result.success(false))
        }

    }

    override fun startAnalysis() {
        cameraState.apply {
            enableImageStream = true
            updateLifecycle(activity!!)
        }
    }

    override fun stopAnalysis() {
        cameraState.apply {
            enableImageStream = false
            updateLifecycle(activity!!)
        }
    }

    override fun requestPermissions(
        saveGpsLocation: Boolean, callback: (Result<List<String>>) -> Unit
    ) {
        // On a generic call, don't ask for specific permissions (location, record audio)
        cameraPermissions.requestBasePermissions(
            activity!!,
            saveGps = saveGpsLocation,
            recordAudio = false,
        ) { grantedPermissions ->
            callback(Result.success(grantedPermissions.mapNotNull {
                when (it) {
                    Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION -> CamerAwesomePermission.LOCATION.name.lowercase()
                    Manifest.permission.CAMERA -> CamerAwesomePermission.CAMERA.name.lowercase()
                    Manifest.permission.RECORD_AUDIO -> CamerAwesomePermission.RECORD_AUDIO.name.lowercase()
                    Manifest.permission.WRITE_EXTERNAL_STORAGE -> CamerAwesomePermission.STORAGE.name.lowercase()
                    else -> null
                }
            }))
        }
    }

    private fun getOrientedSize(width: Int, height: Int): Size {
        val portrait = cameraState.portrait
        return Size(
            if (portrait) width else height,
            if (portrait) height else width,
        )
    }

    override fun getPreviewTextureId(cameraPosition: Long): Long {
        return cameraState.textureEntries[cameraPosition.toString()]!!.id()
    }

    /***
     * [fusedLocationClient.getCurrentLocation] takes time, we might want to use
     * [fusedLocationClient.lastLocation] instead to go faster
     */
    @SuppressLint("MissingPermission")
    private fun retrieveLocation(callback: (Location?) -> Unit) {
        if (exifPreferences.saveGPSLocation && ActivityCompat.checkSelfPermission(
                activity!!, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            fusedLocationClient.getCurrentLocation(
                Priority.PRIORITY_HIGH_ACCURACY, cancellationTokenSource.token
            ).addOnCompleteListener {
                if (it.isSuccessful) {
                    callback(it.result)
                } else {
                    if (it.exception != null) {
                        Log.e(
                            CamerawesomePlugin.TAG, "Error finding location", it.exception
                        )
                    }
                    callback(null)
                }
            }
        } else {
            callback(null)
        }
    }

    override fun takePhoto(
        sensors: List<PigeonSensor>, paths: List<String?>, callback: (Result<Boolean>) -> Unit
    ) {
        if (sensors.size != paths.size) {
            throw Exception("sensors and paths must have the same length")
        }
        if (paths.size != cameraState.imageCaptures.size) {
            throw Exception("paths and imageCaptures must have the same length")
        }

        val sensorsMap = sensors.mapIndexed { index, pigeonSensor ->
            pigeonSensor to paths[index]
        }.toMap()
        CoroutineScope(Dispatchers.Main).launch {
            val res: MutableMap<PigeonSensor, Boolean?> =
                sensorsMap.mapValues { null }.toMutableMap()
            for ((index, entry) in sensorsMap.entries.withIndex()) {
                // On Android, path should be specified
                val imageFile = File(entry.value!!)
                imageFile.parentFile?.mkdirs()
                // cameraState.imageCaptures must be in the same order as the sensors / paths lists
                res[entry.key] = takePhotoWith(cameraState.imageCaptures[index], imageFile)
            }
            callback(Result.success(res.all { it.value == true }))
        }
    }

    @SuppressLint("RestrictedApi")
    private suspend fun takePhotoWith(
        imageCapture: ImageCapture, imageFile: File
    ): Boolean = suspendCancellableCoroutine { continuation ->
        val metadata = ImageCapture.Metadata()
        if (cameraState.sensors.size == 1 && cameraState.sensors.first().position == PigeonSensorPosition.FRONT) {
            metadata.isReversedHorizontal = cameraState.mirrorFrontCamera
        }
        val outputFileOptions =
            ImageCapture.OutputFileOptions.Builder(imageFile).setMetadata(metadata).build()
//        for (imageCapture in cameraState.imageCaptures) {
        imageCapture.targetRotation = orientationStreamListener!!.surfaceOrientation
        imageCapture.takePicture(outputFileOptions,
            ContextCompat.getMainExecutor(activity!!),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    if (colorMatrix != null && noneFilter != colorMatrix) {
                        val exif = ExifInterface(outputFileResults.savedUri!!.path!!)

                        val originalBitmap = BitmapFactory.decodeFile(
                            outputFileResults.savedUri?.path
                        )
                        val bitmapCopy = Bitmap.createBitmap(
                            originalBitmap.width, originalBitmap.height, Bitmap.Config.ARGB_8888
                        )

                        val canvas = Canvas(bitmapCopy)
                        canvas.drawBitmap(originalBitmap, 0f, 0f, Paint().apply {
                            colorFilter = ColorMatrixColorFilter(colorMatrix!!.map { it.toFloat() }
                                .toFloatArray())
                        })

                        try {
                            FileOutputStream(outputFileResults.savedUri?.path).use { out ->
                                bitmapCopy.compress(
                                    Bitmap.CompressFormat.JPEG, 100, out
                                )
                            }
                            exif.saveAttributes()
                        } catch (e: IOException) {
                            e.printStackTrace()
                        }
                    }

                    if (exifPreferences.saveGPSLocation) {
                        retrieveLocation {
                            val exif = ExifInterface(outputFileResults.savedUri!!.path!!)
                            outputFileOptions.metadata.location = it
                            exif.setGpsInfo(it)
//                            Log.d("CAMERAX__EXIF", "GPS info saved ${it?.latitude} ${it?.longitude}")
                            // We need to actually save the exif data to the file system
                            exif.saveAttributes()
                            continuation.resume(true)
                        }
                    } else {
                        if (continuation.isActive) continuation.resume(true)
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.e(CamerawesomePlugin.TAG, "Error capturing picture", exception)
                    continuation.resume(false)
                }
            })
//        }
    }

    @SuppressLint("RestrictedApi", "MissingPermission")
    override fun recordVideo(
        sensors: List<PigeonSensor>, paths: List<String?>, callback: (Result<Unit>) -> Unit
    ) {
        if (sensors.size != paths.size) {
            throw Exception("sensors and paths must have the same length")
        }
        if (paths.size != cameraState.videoCaptures.size) {
            throw Exception("paths and imageCaptures must have the same length")
        }

        val requests = sensors.mapIndexed { index, pigeonSensor ->
            pigeonSensor to paths[index]
        }.toMap()
        CoroutineScope(Dispatchers.Main).launch {
            var ignoreAudio = false
            if (cameraState.enableAudioRecording) {
                if (!cameraPermissions.hasPermission(
                        activity!!, listOf(Manifest.permission.RECORD_AUDIO)
                    )
                ) {
                    cameraPermissions.requestPermissions(
                        activity!!,
                        listOf(Manifest.permission.RECORD_AUDIO),
                        CameraPermissions.PERMISSION_RECORD_AUDIO,
                    ) {
                        ignoreAudio = it.isEmpty()
                    }
                } else {
                    ignoreAudio = false
                }
            }


            lastRecordedVideoSubscriptions?.forEach { it.dispose() }
            lastRecordedVideos = buildList {
                for (i in (0 until requests.size)) {
                    this.add(BehaviorSubject.create())
                }
            }
            cameraState.recordings = mutableListOf()
            lastRecordedVideoSubscriptions = mutableListOf()
            for ((index, videoCapture) in cameraState.videoCaptures.values.withIndex()) {
                val recordingListener = Consumer<VideoRecordEvent> { event ->
                    when (event) {
                        is VideoRecordEvent.Start -> {
                            Log.d(CamerawesomePlugin.TAG, "Capture Started")
                        }

                        is VideoRecordEvent.Finalize -> {
                            if (!event.hasError()) {
                                Log.d(
                                    CamerawesomePlugin.TAG,
                                    "Video capture succeeded: ${event.outputResults.outputUri}"
                                )
                                lastRecordedVideos!![index].onNext(true)
                            } else {
                                // update app state when the capture failed.
                                cameraState.apply {
                                    recordings?.get(index)?.close()
                                    if (recordings?.all {
                                            it.isClosed
                                        } == true) {
                                        recordings = null
                                    }
                                }
                                Log.e(
                                    CamerawesomePlugin.TAG,
                                    "Video capture ends with error: ${event.error}"
                                )
                                lastRecordedVideos!![index].onNext(false)
                            }
                        }
                    }
                }
                videoCapture.targetRotation = orientationStreamListener!!.surfaceOrientation
                cameraState.recordings!!.add(videoCapture.output.prepareRecording(
                    activity!!, FileOutputOptions.Builder(File(paths[index]!!)).build()
                ).apply { if (cameraState.enableAudioRecording && !ignoreAudio) withAudioEnabled() }
                    .start(cameraState.executor(activity!!), recordingListener))
            }
            callback(Result.success(Unit))
        }
    }

    override fun stopRecordingVideo(callback: (Result<Boolean>) -> Unit) {
        var submitted = false
        for (index in 0 until cameraState.recordings!!.size) {
            val countDownTimer = object : CountDownTimer(5000, 5000) {
                override fun onTick(interval: Long) {}
                override fun onFinish() {
                    if (!submitted) {
                        submitted = true
                        callback(Result.success(false))
                    }
                }
            }
            countDownTimer.start()

            cameraState.recordings!![index].stop()
            lastRecordedVideoSubscriptions!!.add(lastRecordedVideos!![index].subscribe({ it ->
                countDownTimer.cancel()
                if (!submitted) {
                    submitted = true
                    callback(Result.success(it))
                }
            }, { error -> error.printStackTrace() }))
        }
    }

    override fun getFrontSensors(): List<PigeonSensorTypeDevice> {
        TODO("Not yet implemented")
    }

    override fun getBackSensors(): List<PigeonSensorTypeDevice> {
        TODO("Not yet implemented")
    }

    override fun pauseVideoRecording() {
        cameraState.recordings?.forEach { it.pause() }
    }

    override fun resumeVideoRecording() {
        cameraState.recordings?.forEach { it.resume() }
    }

    override fun receivedImageFromStream() {
        cameraState.imageAnalysisBuilder?.lastFrameAnalysisFinished()
    }


    override fun start(): Boolean {
        // Already started on setUp
        currentCameraStateOrNull()?.let { state ->
            B2NativeSpikeTelemetry.recordResume(
                context = B2NativeSpikeTelemetry.snapshot(),
                nativeSessionId = state.nativeSessionIdForSpike(),
                lens = state.actualLensForSpike(),
            )
        }
        return true
    }

    override fun stop(): Boolean {
        currentCameraStateOrNull()?.let { state ->
            B2NativeSpikeTelemetry.recordPause(
                context = B2NativeSpikeTelemetry.snapshot(),
                nativeSessionId = state.nativeSessionIdForSpike(),
                lens = state.actualLensForSpike(),
            )
        }
        orientationStreamListener?.stop()
        cameraState.stop()
        return true
    }

    @SuppressLint("RestrictedApi")
    override fun setFlashMode(mode: String) {
        val flashMode = FlashMode.valueOf(mode)
        cameraState.apply {
            this.flashMode = flashMode
            for (imageCapture in cameraState.imageCaptures) {
                imageCapture.flashMode = when (flashMode) {
                    FlashMode.ALWAYS, FlashMode.ON -> ImageCapture.FLASH_MODE_ON
                    FlashMode.AUTO -> ImageCapture.FLASH_MODE_AUTO
                    else -> ImageCapture.FLASH_MODE_OFF
                }
            }
            (cameraState.concurrentCamera?.cameras?.firstOrNull()
                ?: cameraState.previewCamera)?.cameraControl?.enableTorch(flashMode == FlashMode.ALWAYS)
        }
    }

    override fun handleAutoFocus() {
        focus()
    }

    override fun setZoom(zoom: Double) {
        cameraState.setZoom(zoom.toFloat())
    }

    @SuppressLint("RestrictedApi")
    override fun setSensor(sensors: List<PigeonSensor>) {
        cameraState.apply {
            val spikeContext = B2NativeSpikeTelemetry.snapshot()
            val previousLens = actualLensForSpike()
            B2NativeSpikeTelemetry.emit(
                context = spikeContext,
                event = "lens_switch",
                eventDetail = "set_sensor_request",
                nativeSessionId = nativeSessionIdForSpike(),
                lens = previousLens,
                nativeApplied = false,
            )
            this.sensors = sensors
            // TODO Make below variables parameters
            // Also reset flash mode and aspect ratio
            this.flashMode = FlashMode.NONE
            this.aspectRatio = null
            this.rational = Rational(3, 4)
            updateLifecycle(activity!!)
            B2NativeSpikeTelemetry.emit(
                context = spikeContext,
                event = "lens_switch",
                eventDetail = "set_sensor_committed",
                nativeSessionId = nativeSessionIdForSpike(),
                lens = actualLensForSpike(),
                nativeApplied = true,
            )
        }
    }

    @SuppressLint("RestrictedApi")
    override fun setCorrection(brightness: Double) {
        // TODO brightness calculation might not be the same as before CameraX
        val range = (cameraState.concurrentCamera?.cameras?.firstOrNull()
            ?: cameraState.previewCamera!!).cameraInfo.exposureState.exposureCompensationRange
        val actualBrightnessValue = brightness * (range.upper - range.lower) + range.lower
        cameraState.previewCamera?.cameraControl?.setExposureCompensationIndex(
            actualBrightnessValue.roundToInt()
        )
    }

    /**
     * This method must be called after bindToLifecycle has been called
     *
     * @return the max zoom ratio
     */
    override fun getMaxZoom(): Double {
        return cameraState.maxZoomRatio
    }

    /**
     * This method must be called after bindToLifecycle has been called
     *
     * @return the min zoom ratio
     */
    override fun getMinZoom(): Double {
        return cameraState.minZoomRatio
    }

    fun convertLinearToRatio(linear: Double): Double {
        // TODO Not sure if this is correct
        return linear * getMaxZoom() / getMinZoom()
    }

    @Deprecated("Use focusOnPoint instead")
    fun focus() {
        val autoFocusPoint = SurfaceOrientedMeteringPointFactory(1f, 1f).createPoint(.5f, .5f)
        try {
            val autoFocusAction = FocusMeteringAction.Builder(
                autoFocusPoint, FocusMeteringAction.FLAG_AF
            ).apply {
                //start auto-focusing after 2 seconds
                setAutoCancelDuration(2, TimeUnit.SECONDS)
            }.build()
            cameraState.startFocusAndMetering(autoFocusAction)
        } catch (e: CameraInfoUnavailableException) {
            throw e
        }
    }

    @SuppressLint("RestrictedApi")
    override fun focusOnPoint(
        previewSize: PreviewSize,
        x: Double,
        y: Double,
        androidFocusSettings: AndroidFocusSettings?,
    ) {
        val autoCancelDurationInMillis = androidFocusSettings?.autoCancelDurationInMillis ?: 2500L
        val factory: MeteringPointFactory = SurfaceOrientedMeteringPointFactory(
            previewSize.width.toFloat(), previewSize.height.toFloat(),
        )

        val autoFocusPoint = factory.createPoint(x.toFloat(), y.toFloat())
        try {
            (cameraState.concurrentCamera?.cameras?.firstOrNull()
                ?: cameraState.previewCamera!!).cameraControl.startFocusAndMetering(
                FocusMeteringAction.Builder(
                    autoFocusPoint,
                    FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE or FocusMeteringAction.FLAG_AWB
                ).apply {
                    if (autoCancelDurationInMillis <= 0) {
                        disableAutoCancel()
                    } else {
                        setAutoCancelDuration(autoCancelDurationInMillis, TimeUnit.MILLISECONDS)
                    }
                }.build()
            )
        } catch (e: CameraInfoUnavailableException) {
            throw e
        }
    }

    @SuppressLint("RestrictedApi")
    override fun setCaptureMode(mode: String) {
        cameraState.apply {
            setCaptureMode(CaptureModes.valueOf(mode))
            updateLifecycle(activity!!)
        }
    }


    @SuppressLint("RestrictedApi")
    @ExperimentalCamera2Interop
    override fun isMultiCamSupported(): Boolean {
        return getCameraProvider().isMultiCamSupported()
    }

    /// Changing the recording audio mode can't be changed once a recording has starded
    override fun setRecordingAudioMode(
        enableAudio: Boolean, callback: (Result<Boolean>) -> Unit
    ) {
        CoroutineScope(Dispatchers.IO).launch {
            cameraPermissions.requestPermissions(
                activity!!,
                listOf(Manifest.permission.RECORD_AUDIO),
                CameraPermissions.PERMISSION_RECORD_AUDIO,
            ) { granted ->
                if (granted.isNotEmpty()) {
                    cameraState.apply {
                        enableAudioRecording = enableAudio
                        // No need to update lifecycle, it will be applied on next recording
                    }
                }
                Dispatchers.Main.run { callback(Result.success(granted.isNotEmpty())) }
            }
        }
    }

    @SuppressLint("RestrictedApi", "UnsafeOptInUsageError")
    override fun availableSizes(): List<PreviewSize> {
        return cameraState.previewSizes().map {
            PreviewSize(
                width = it.width.toDouble(), height = it.height.toDouble()
            )
        }
    }

    override fun refresh() {
//        TODO Nothing to do?
    }

    @SuppressLint("RestrictedApi")
    override fun getEffectivPreviewSize(index: Long): PreviewSize {
        val preview = cameraState.previews?.getOrNull(index.toInt()) ?: return PreviewSize(0.0, 0.0)
        val resolutionInfo = preview.resolutionInfo ?: return PreviewSize(0.0, 0.0)
        val res = resolutionInfo.resolution

        val rotation = resolutionInfo.rotationDegrees
        val previewSize = when (rotation) {
            90, 270 -> PreviewSize(res.height.toDouble(), res.width.toDouble())
            else -> PreviewSize(res.width.toDouble(), res.height.toDouble())
        }

        Log.d("CameraX", "Preview size: width=${previewSize.width}, height=${previewSize.height}, rotation=$rotation")
        return previewSize
    }

    @SuppressLint("RestrictedApi")
    override fun setPhotoSize(size: PreviewSize) {
        cameraState.apply {
            photoSize = getOrientedSize(size.width.toInt(), size.height.toInt())
            updateLifecycle(activity!!)
        }
    }

    @SuppressLint("RestrictedApi")
    override fun setPreviewSize(size: PreviewSize) {
        cameraState.apply {
            previewSize = getOrientedSize(size.width.toInt(), size.height.toInt())
            updateLifecycle(activity!!)
        }
    }

    override fun setAspectRatio(aspectRatio: String) {
        cameraState.apply {
            this.updateAspectRatio(aspectRatio)
            updateLifecycle(activity!!)
        }
    }

    override fun setMirrorFrontCamera(mirror: Boolean) {
        cameraState.apply {
            this.mirrorFrontCamera = mirror
            updateLifecycle(activity!!)
        }
    }


    //    FLUTTER ATTACHMENTS
    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        this.binding = binding
        textureRegistry = binding.textureRegistry
        CameraInterface.setUp(binding.binaryMessenger, this)
        AnalysisImageUtils.setUp(binding.binaryMessenger, AnalysisImageConverter())
        orientationStreamChannel = EventChannel(binding.binaryMessenger, "camerawesome/orientation")
        orientationStreamChannel.setStreamHandler(sensorOrientationListener)
        imageStreamChannel = EventChannel(binding.binaryMessenger, "camerawesome/images")
        EventChannel(binding.binaryMessenger, "camerawesome/permissions").setStreamHandler(
            cameraPermissions
        )
        physicalButtonHandler = PhysicalButtonsHandler()
        EventChannel(binding.binaryMessenger, "camerawesome/physical_button").setStreamHandler(
            physicalButtonHandler
        )
        nativeSpikeChannel = MethodChannel(
            binding.binaryMessenger,
            B2NativeSpikeTelemetry.CHANNEL_NAME,
        ).also { channel ->
            B2NativeSpikeTelemetry.attachChannel(channel)
            channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        B2NativeSpikeTelemetry.METHOD_SET_CONTEXT -> {
                            val revision = B2NativeSpikeTelemetry.setContext(call.arguments)
                            result.success(mapOf("contextRevision" to revision))
                        }
                        B2NativeSpikeTelemetry.METHOD_FINISH_CONTEXT -> {
                            B2NativeSpikeTelemetry.finishContext(call.arguments, result::success)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: IllegalArgumentException) {
                    result.error(
                        "B2_NATIVE_SPIKE_INVALID_CONTEXT",
                        error.message,
                        null,
                    )
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        B2NativeSpikeTelemetry.detachChannel(nativeSpikeChannel)
        nativeSpikeChannel?.setMethodCallHandler(null)
        nativeSpikeChannel = null
        B2NativeSpikeTelemetry.clearContext()
        this.binding = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(cameraPermissions)
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(cameraPermissions)
    }

    override fun onDetachedFromActivity() {
        activity = null
        cancellationTokenSource.cancel()
        cameraPermissions.onCancel(null)
    }

    private fun currentCameraStateOrNull(): CameraXState? {
        return if (::cameraState.isInitialized) cameraState else null
    }

}
