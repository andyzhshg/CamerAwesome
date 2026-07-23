package com.apparence.camerawesome.cameraX.preview

import android.graphics.Rect
import android.util.Log
import io.flutter.plugin.common.EventChannel

class PreviewTransformPublisher : EventChannel.StreamHandler {
    private data class Session(
        val id: Long,
        val textureId: Long,
        val bufferWidth: Int,
        val bufferHeight: Int,
        var revision: Long = 0,
    )

    private var eventSink: EventChannel.EventSink? = null
    private var latestEvent: Map<String, Any>? = null
    private var nextSessionId = 0L
    private var activeSession: Session? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        latestEvent?.let { events?.success(it) }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun startSession(
        textureId: Long,
        bufferWidth: Int,
        bufferHeight: Int,
    ): Long {
        require(bufferWidth > 0 && bufferHeight > 0) {
            "Preview buffer dimensions must be positive"
        }

        invalidateActiveSession()
        val session = Session(
            id = ++nextSessionId,
            textureId = textureId,
            bufferWidth = bufferWidth,
            bufferHeight = bufferHeight,
        )
        activeSession = session
        emitInvalidated(session)
        return session.id
    }

    fun publish(
        sessionId: Long,
        transformationRotationDegrees: Int,
        sensorRotationDegrees: Int,
        cropRect: Rect,
        isMirroring: Boolean,
        hasCameraTransform: Boolean,
    ) {
        val session = activeSession
        if (session == null || session.id != sessionId) {
            return
        }

        val isFullBufferCrop = cropRect.left == 0 &&
            cropRect.top == 0 &&
            cropRect.right == session.bufferWidth &&
            cropRect.bottom == session.bufferHeight
        if (!hasCameraTransform || !isFullBufferCrop) {
            Log.w(
                TAG,
                "Rejecting preview transform session=$sessionId " +
                    "hasCameraTransform=$hasCameraTransform crop=$cropRect " +
                    "buffer=${session.bufferWidth}x${session.bufferHeight}",
            )
            session.revision += 1
            emitInvalidated(session)
            return
        }

        val quarterTurns = try {
            presentationQuarterTurns(
                transformationRotationDegrees = transformationRotationDegrees,
                sensorRotationDegrees = sensorRotationDegrees,
                isMirroring = isMirroring,
            )
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "Rejecting non-quarter preview transform", error)
            session.revision += 1
            emitInvalidated(session)
            return
        }

        session.revision += 1
        val swapsDimensions = quarterTurns % 2 == 1
        emit(
            mapOf(
                "event" to "ready",
                "sessionId" to session.id,
                "textureId" to session.textureId,
                "revision" to session.revision,
                "presentationQuarterTurns" to quarterTurns,
                "bufferWidth" to session.bufferWidth,
                "bufferHeight" to session.bufferHeight,
                "orientedWidth" to if (swapsDimensions) {
                    session.bufferHeight
                } else {
                    session.bufferWidth
                },
                "orientedHeight" to if (swapsDimensions) {
                    session.bufferWidth
                } else {
                    session.bufferHeight
                },
                "cropLeft" to cropRect.left,
                "cropTop" to cropRect.top,
                "cropWidth" to cropRect.width(),
                "cropHeight" to cropRect.height(),
                "isMirroring" to isMirroring,
                "hasCameraTransform" to hasCameraTransform,
            ),
        )
    }

    fun invalidateSession(sessionId: Long) {
        val session = activeSession
        if (session == null || session.id != sessionId) {
            return
        }
        session.revision += 1
        emitInvalidated(session)
    }

    fun invalidateActiveSession() {
        val session = activeSession ?: return
        session.revision += 1
        emitInvalidated(session)
        activeSession = null
    }

    private fun emitInvalidated(session: Session) {
        emit(
            mapOf(
                "event" to "invalidated",
                "sessionId" to session.id,
                "revision" to session.revision,
            ),
        )
    }

    private fun emit(event: Map<String, Any>) {
        latestEvent = event
        eventSink?.success(event)
    }

    private companion object {
        const val TAG = "PreviewTransform"
    }
}
