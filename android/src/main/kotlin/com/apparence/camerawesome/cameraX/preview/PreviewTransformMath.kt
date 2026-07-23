package com.apparence.camerawesome.cameraX.preview

fun presentationQuarterTurns(
    transformationRotationDegrees: Int,
    sensorRotationDegrees: Int,
    isMirroring: Boolean,
): Int {
    val normalizedTransformation = normalize360(transformationRotationDegrees)
    val normalizedSensor = normalize360(sensorRotationDegrees)
    require(normalizedTransformation % 90 == 0) {
        "Transformation rotation must be a multiple of 90 degrees"
    }
    require(normalizedSensor % 90 == 0) {
        "Sensor rotation must be a multiple of 90 degrees"
    }

    val rawDelta = normalize360(normalizedTransformation - normalizedSensor)
    val presentationDegrees = if (isMirroring) {
        normalize360(-rawDelta)
    } else {
        rawDelta
    }
    return presentationDegrees / 90
}

private fun normalize360(degrees: Int): Int = ((degrees % 360) + 360) % 360
