package com.mattmacosko.realtimeaicam.aim

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

// Kareen (Blind Android Users, 2026-09-25): Help Me Aim's photos had the
// subject in them but "usually not in the centre", and a photo frame "was
// taken at an angle". Same tests as the iPhone's KareenCenteringTests.

private fun box(midX: Float, midY: Float, w: Float, h: Float) =
    AimRect(midX - w / 2f, midY - h / 2f, w, h)

private fun pt(x: Float, y: Float) = AimPoint(x, y)

class KareenCenteringTest {
    private val pw = 3000f
    private val ph = 4000f

    @Test fun smallSubjectsKeepTheWideZone() {
        assertEquals(AimSteering.wholeTolerance, AimSteering.centerTolerance(0.3f, false), 1e-6f)
        assertEquals(AimSteering.wholeLooseTolerance, AimSteering.centerTolerance(0.3f, true), 1e-6f)
    }

    @Test fun bigSubjectsGetATighterZoneButNeverTiny() {
        val t6 = AimSteering.centerTolerance(0.6f, false)
        assertEquals((1f - 0.6f / 0.9f) / 2f, t6, 1e-5f)
        assertEquals(AimSteering.bigSubjectMinTolerance, AimSteering.centerTolerance(0.9f, false), 1e-6f)
        assertTrue(AimSteering.centerTolerance(0.6f, true) > t6)
    }

    @Test fun bigPictureOffToTheSideIsSteered() {
        val off = box(0.3f, 0.5f, 0.6f, 0.5f)
        assertEquals(AimInstruction.MOVE_LEFT, AimSteering.instruction(off, AimSteering.Framing.PAGE))
        assertEquals(AimInstruction.MOVE_LEFT, AimSteering.instruction(off, AimSteering.Framing.WHOLE))
        val near = box(0.4f, 0.5f, 0.6f, 0.5f)
        assertEquals(AimInstruction.FRAMED, AimSteering.instruction(near, AimSteering.Framing.PAGE))
    }

    @Test fun bigObjectsAreMovedToTheMiddleWithLessPadding() {
        val b = box(0.4f, 0.5f, 0.6f, 0.4f)
        val c = AimBurst.crop(b, pw, ph, AimSteering.Framing.WHOLE)
        assertNotNull(c)
        assertEquals(0.5f, (b.midX * pw - c!!.minX) / c.width, 0.01f)
        assertNull(AimBurst.crop(box(0.47f, 0.5f, 0.9f, 0.5f), pw, ph, AimSteering.Framing.WHOLE))
    }

    /** Whatever the tight zone calls framed, the crop finishes centring. */
    @Test fun everyFramedObjectEndsUpCentered() {
        var size = 0.12f
        while (size <= 0.86f) {
            val tol = AimSteering.centerTolerance(size, false)
            for (sign in listOf(-1f, 1f)) {
                val b = box(0.5f + sign * (tol - 0.001f), 0.5f, size, size * 0.75f)
                if (AimSteering.instruction(b, AimSteering.Framing.WHOLE) != AimInstruction.FRAMED) continue
                val c = AimBurst.crop(b, pw, ph, AimSteering.Framing.WHOLE)
                if (c != null) {
                    val x = (b.midX * pw - c.minX) / c.width
                    assertTrue("size $size sign $sign: x $x", abs(x - 0.5f) < 0.02f)
                } else {
                    assertTrue("size $size not cropped", abs(b.midX - 0.5f) <= AimBurst.wellFramedDistance + 1e-5f)
                }
            }
            size += 0.02f
        }
    }

    private val tilted = AimQuad(pt(0.25f, 0.2f), pt(0.8f, 0.25f), pt(0.75f, 0.8f), pt(0.2f, 0.75f))

    @Test fun tiltedQuadIsUsable() {
        assertTrue(AimStraighten.usable(tilted, pw, ph))
    }

    @Test fun badQuadsAreRefused() {
        assertFalse(AimStraighten.usable(AimQuad(pt(0f, 0.2f), pt(0.8f, 0.2f), pt(0.8f, 0.8f), pt(0.1f, 0.8f)), pw, ph))
        assertFalse(AimStraighten.usable(AimQuad(pt(0.5f, 0.5f), pt(0.6f, 0.5f), pt(0.6f, 0.6f), pt(0.5f, 0.6f)), pw, ph))
        assertFalse(AimStraighten.usable(AimQuad(pt(0.2f, 0.2f), pt(0.8f, 0.8f), pt(0.8f, 0.2f), pt(0.2f, 0.8f)), pw, ph))
        assertFalse(AimStraighten.usable(AimQuad(pt(0.45f, 0.2f), pt(0.55f, 0.2f), pt(0.9f, 0.8f), pt(0.1f, 0.8f)), pw, ph))
        assertFalse(AimStraighten.usable(null, pw, ph))
    }

    @Test fun outputSizeFollowsTheLongerSides() {
        val q = AimQuad(pt(0.2f, 0.2f), pt(0.8f, 0.2f), pt(0.8f, 0.6f), pt(0.2f, 0.6f))
        assertEquals(Pair(600f, 400f), AimStraighten.outputSize(q, 1000f, 1000f))
    }

    /** Point-in-convex-quad, for drawing a test page. */
    private fun inside(q: AimQuad, x: Float, y: Float): Boolean {
        val p = q.corners
        for (i in 0 until 4) {
            val a = p[i]
            val b = p[(i + 1) % 4]
            if ((b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x) < 0) return false
        }
        return true
    }

    private fun draw(q: AimQuad, w: Int, h: Int, noise: Boolean = false): FloatArray {
        val rng = java.util.Random(3)
        return FloatArray(w * h) { i ->
            val x = (i % w + 0.5f) / w
            val y = (i / w + 0.5f) / h
            val base = if (inside(q, x, y)) 230f else 50f
            if (noise) base + rng.nextGaussian().toFloat() * 8f else base
        }
    }

    @Test fun findsTheCornersOfATiltedPage() {
        val w = 480
        val h = 640
        // The detector's box: roughly around the page, a little loose.
        val b = AimRect(0.18f, 0.18f, 0.64f, 0.64f)
        val found = AimQuadFinder.find(draw(tilted, w, h, noise = true), w, h, b)
        assertNotNull(found)
        for ((got, want) in found!!.corners.zip(tilted.corners)) {
            assertEquals(want.x, got.x, 0.01f)
            assertEquals(want.y, got.y, 0.01f)
        }
        assertTrue(AimStraighten.usable(found, w.toFloat(), h.toFloat()))
    }

    @Test fun noEdgesMeansNoCorners() {
        val w = 320
        val h = 320
        val flat = FloatArray(w * h) { 120f }
        assertNull(AimQuadFinder.find(flat, w, h, AimRect(0.2f, 0.2f, 0.6f, 0.6f)))
    }

    @Test fun aPageRunningOffTheBoxIsRefused() {
        // The page is much bigger than the box: its edges are not near the box.
        val w = 400
        val h = 400
        val big = AimQuad(pt(0.02f, 0.02f), pt(0.98f, 0.02f), pt(0.98f, 0.98f), pt(0.02f, 0.98f))
        assertNull(AimQuadFinder.find(draw(big, w, h), w, h, AimRect(0.35f, 0.35f, 0.3f, 0.3f)))
    }
}
