package com.apparence.camerawesome.cameraX.preview

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PreviewTransformMathTest {
    @Test
    fun backCameraPortrait() {
        assertEquals(0, presentationQuarterTurns(90, 90, false))
    }

    @Test
    fun backCameraLeftLandscape() {
        assertEquals(3, presentationQuarterTurns(0, 90, false))
    }

    @Test
    fun backCameraRightLandscape() {
        assertEquals(1, presentationQuarterTurns(180, 90, false))
    }

    @Test
    fun backCameraUpsideDown() {
        assertEquals(2, presentationQuarterTurns(270, 90, false))
    }

    @Test
    fun mirroredFrontCameraEquivalents() {
        assertEquals(0, presentationQuarterTurns(270, 270, true))
        assertEquals(3, presentationQuarterTurns(0, 270, true))
        assertEquals(1, presentationQuarterTurns(180, 270, true))
        assertEquals(2, presentationQuarterTurns(90, 270, true))
    }

    @Test
    fun normalizesNegativeDeltas() {
        assertEquals(3, presentationQuarterTurns(0, 90, false))
        assertEquals(1, presentationQuarterTurns(0, 90, true))
    }

    @Test
    fun rejectsNonQuarterDegreeInputs() {
        assertThrows(IllegalArgumentException::class.java) {
            presentationQuarterTurns(45, 90, false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            presentationQuarterTurns(90, 45, false)
        }
    }
}
