package com.mattmacosko.realtimeaicam.aim

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

// MARK: - Help Me Aim: the pure part
//
// "Help Me Aim" talks a blind photographer into the shot and then takes it.
// Dennis Long asked for it by name ("I'm trying to replicate the pixel", i.e.
// Google's Pixel Guided Frame, 2026-09-15), Amrit on AppleVis asked for the
// same thing, and the AppleVis threads on selfie apps set the rules this file
// follows: the countdown is said once, a person's face sits in the upper part
// of the frame unless it is a close-up, and guidance has to survive leaving
// the app and coming back.
//
// The person says WHAT they want a picture of first, so the app never guesses
// a subject.
//
// This is a line-for-line port of iOS `HelpMeAim.swift`. Matt's rule
// (2026-09-20): every feature built for iPhone gets built for Android too, and
// the SPOKEN WORDS MUST MATCH, so the answer given on AppleVis is the same
// answer given on Google Play. If you change a phrase here, change it there.
//
// Everything in this file is arithmetic on boxes that were already measured,
// so it is unit tested without a camera. Boxes are normalized to the upright
// frame with the origin at the TOP-LEFT and y growing downward.
//
// Times are seconds as Double, exactly like the iOS original, so the two
// files can be read side by side. Callers pass SystemClock.elapsedRealtime()
// divided by 1000.

/** Normalized rectangle, top-left origin, y growing downward. */
data class AimRect(val x: Float, val y: Float, val width: Float, val height: Float) {
    val minX get() = x
    val minY get() = y
    val maxX get() = x + width
    val maxY get() = y + height
    val midX get() = x + width / 2f
    val midY get() = y + height / 2f

    fun contains(px: Float, py: Float): Boolean = px in minX..maxX && py in minY..maxY

    /** Null when they do not overlap, matching CGRect.intersection + isNull. */
    fun intersection(other: AimRect): AimRect? {
        val l = max(minX, other.minX)
        val t = max(minY, other.minY)
        val r = min(maxX, other.maxX)
        val b = min(maxY, other.maxY)
        if (r <= l || b <= t) return null
        return AimRect(l, t, r - l, b - t)
    }

    fun insetBy(dx: Float, dy: Float) = AimRect(x + dx, y + dy, width - 2 * dx, height - 2 * dy)

    companion object {
        fun fromEdges(minX: Float, minY: Float, maxX: Float, maxY: Float) =
            AimRect(minX, minY, max(0f, maxX - minX), max(0f, maxY - minY))
    }
}

data class AimPoint(val x: Float, val y: Float)

/** What the person asked for. */
sealed class AimSubject {
    object Face : AimSubject()
    object Page : AimSubject()
    data class Obj(val match: AimVocabulary.Match) : AimSubject()

    /** "a face", "a picture or page", "a key". */
    val spokenName: String
        get() = when (this) {
            is Face -> "a face"
            is Page -> "a picture or page"
            is Obj -> AimVocabulary.withArticle(match.spokenName)
        }

    val framing: AimSteering.Framing
        get() = when (this) {
            is Face -> AimSteering.Framing.PERSON
            is Page -> AimSteering.Framing.PAGE
            is Obj -> AimSteering.Framing.WHOLE
        }
}

/** One thing the coach can tell the person. */
enum class AimInstruction {
    NOT_FOUND,
    MOVE_LEFT, MOVE_RIGHT, MOVE_UP, MOVE_DOWN,
    MOVE_CLOSER, BACK_UP,

    /** Back up because the subject runs off two or more edges (pages). */
    BACK_UP_CUT_OFF,
    FRAMED,
}

// MARK: - Steering

object AimSteering {
    enum class Framing {
        /**
         * Faces and people: upper third, horizontally centered, unless the face
         * fills the shot (then centered). A photographer's rule, raised on
         * AppleVis ("Taking professional photos", 2023): "centered" is the
         * wrong target for a person.
         */
        PERSON,

        /** Objects: centered and not cut off at any edge. */
        WHOLE,

        /**
         * Pictures and pages: like WHOLE, but all four corners have to be
         * clearly inside before "got it" (walkaround 2026-09-16: a page cut off
         * at the edge was called framed).
         */
        PAGE,
    }

    // Round 2 (Matt's field test, 2026-09-16: shot about 1 in 30 tries and
    // chattered): the good-enough zone is roughly the middle half of the frame,
    // "cut off" means really touching the edge, and "move closer" is only for a
    // subject that is tiny. The shot is taken wide and cropped afterwards
    // (AimBurst.crop), so the live framing can be generous.

    // Person framing.
    const val personTolerance = 0.22f
    const val personLooseTolerance = 0.32f
    const val upperThird = 1f / 3f

    /** Below this face height the face goes in the upper third... */
    const val closeUpStart = 0.30f

    /** ...above this it is a close-up and goes in the middle. */
    const val closeUpFull = 0.40f
    const val personTooSmall = 0.08f
    const val personLooseTooSmall = 0.06f
    const val personTooBig = 0.75f
    const val personLooseTooBig = 0.85f

    // Whole-object framing.
    const val wholeTolerance = 0.25f
    const val wholeLooseTolerance = 0.33f

    /** A box edge this close to the frame edge is cut off. */
    const val edgeMargin = 0.005f
    const val looseEdgeMargin = 0.001f
    const val wholeTooSmall = 0.10f
    const val wholeLooseTooSmall = 0.08f
    const val wholeTooBig = 0.97f

    /**
     * Covering more of the frame than this: back up (walkaround 2026-09-16, a
     * wall map bigger than the frame bounced up/right/down/left for 15 s).
     */
    const val tooMuchOfFrame = 0.85f

    /** Pages: every corner at least this far inside. */
    const val pageEdgeMargin = 0.02f
    const val pageLooseEdgeMargin = 0.01f

    // Big subjects (Kareen, Blind Android Users, 2026-09-25: "the subjects
    // were usually not in the centre of the photo", a picture frame came out
    // off to one side). The after-shot crop can only slide a subject to the
    // middle while the crop still fits in the photo, and a subject that fills
    // most of the frame leaves no room to slide. So "got it" for a big subject
    // waits until it is close enough that the crop can finish the job; a small
    // subject keeps the wide middle-half zone from round 2.
    /** Never tighter than this, so a big subject is still easy to land. */
    const val bigSubjectMinTolerance = 0.08f

    /** The loose (countdown) zone is this much wider than the tight one. */
    const val bigSubjectLooseExtra = 0.08f

    /**
     * How far the middle of an object may sit from the middle of the frame and
     * still count as framed. [size] is the subject's bigger side.
     */
    fun centerTolerance(size: Float, loose: Boolean): Float {
        val base = if (loose) wholeLooseTolerance else wholeTolerance
        // The crop is size / bigObjectFill wide, so it can recentre a subject
        // that is at most half the leftover room off the middle.
        val fixable = (1f - size / AimBurst.bigObjectFill) / 2f
        val tight = max(bigSubjectMinTolerance, fixable) + (if (loose) bigSubjectLooseExtra else 0f)
        return min(base, tight)
    }

    /**
     * What to tell the person for this box. [loose] is the much wider zone used
     * once "got it" has been said and while the countdown runs, so a hand's
     * normal wobble does not undo it.
     */
    fun instruction(box: AimRect?, framing: Framing, loose: Boolean = false): AimInstruction {
        val b = box ?: return AimInstruction.NOT_FOUND
        if (b.width <= 0f || b.height <= 0f) return AimInstruction.NOT_FOUND
        return when (framing) {
            Framing.PERSON -> personInstruction(b, loose)
            Framing.WHOLE -> wholeInstruction(b, loose, page = false)
            Framing.PAGE -> wholeInstruction(b, loose, page = true)
        }
    }

    /** Where the middle of the subject belongs. */
    fun target(box: AimRect, framing: Framing): AimPoint {
        if (framing != Framing.PERSON) return AimPoint(0.5f, 0.5f)
        if (box.height > closeUpFull) return AimPoint(0.5f, 0.5f)
        if (box.height < closeUpStart) return AimPoint(0.5f, upperThird)
        // In between: slide from the upper third to the middle.
        val t = (box.height - closeUpStart) / (closeUpFull - closeUpStart)
        return AimPoint(0.5f, upperThird + (0.5f - upperThird) * t)
    }

    fun isCutOff(b: AimRect, margin: Float = edgeMargin): Boolean =
        b.minX < margin || b.minY < margin || b.maxX > 1 - margin || b.maxY > 1 - margin

    private fun personInstruction(b: AimRect, loose: Boolean): AimInstruction {
        val tol = if (loose) personLooseTolerance else personTolerance
        val size = max(b.width, b.height)
        if (size > (if (loose) personLooseTooBig else personTooBig)) return AimInstruction.BACK_UP

        // Face really running off an edge: fix that first.
        val m = if (loose) looseEdgeMargin else edgeMargin
        if (b.minY < m) return AimInstruction.MOVE_UP
        if (b.maxY > 1 - m) return AimInstruction.MOVE_DOWN
        if (b.minX < m) return AimInstruction.MOVE_LEFT
        if (b.maxX > 1 - m) return AimInstruction.MOVE_RIGHT

        // Top-to-bottom: upper third for a small face, middle for a close-up,
        // either in between.
        val low: Float
        val high: Float
        if (b.height < closeUpStart) {
            low = upperThird - tol; high = upperThird + tol
        } else if (b.height > closeUpFull) {
            low = 0.5f - tol; high = 0.5f + tol
        } else {
            low = upperThird - tol; high = 0.5f + tol
        }
        val dx = b.midX - 0.5f
        val xOff = max(0f, abs(dx) - tol)
        val yOff = if (b.midY < low) low - b.midY else if (b.midY > high) b.midY - high else 0f
        if (xOff > 0f || yOff > 0f) {
            if (xOff >= yOff) return if (dx < 0) AimInstruction.MOVE_LEFT else AimInstruction.MOVE_RIGHT
            return if (b.midY < low) AimInstruction.MOVE_UP else AimInstruction.MOVE_DOWN
        }
        if (size < (if (loose) personLooseTooSmall else personTooSmall)) return AimInstruction.MOVE_CLOSER
        return AimInstruction.FRAMED
    }

    private fun wholeInstruction(b: AimRect, loose: Boolean, page: Boolean): AimInstruction {
        val m = if (page) {
            if (loose) pageLooseEdgeMargin else pageEdgeMargin
        } else {
            if (loose) looseEdgeMargin else edgeMargin
        }
        val cutL = b.minX < m
        val cutR = b.maxX > 1 - m
        val cutT = b.minY < m
        val cutB = b.maxY > 1 - m
        val edgesCut = listOf(cutL, cutR, cutT, cutB).count { it }
        // Touching two or more edges means it's bigger than the frame (or
        // nearly): moving toward one edge only pushes another out.
        if (edgesCut >= 2) {
            return if (page) AimInstruction.BACK_UP_CUT_OFF else AimInstruction.BACK_UP
        }
        if (b.width > wholeTooBig || b.height > wholeTooBig || b.width * b.height > tooMuchOfFrame) {
            return AimInstruction.BACK_UP
        }
        // One edge cut off: move toward it and the rest comes into the picture.
        if (cutL) return AimInstruction.MOVE_LEFT
        if (cutR) return AimInstruction.MOVE_RIGHT
        if (cutT) return AimInstruction.MOVE_UP
        if (cutB) return AimInstruction.MOVE_DOWN

        val tol = centerTolerance(max(b.width, b.height), loose)
        val dx = b.midX - 0.5f
        val dy = b.midY - 0.5f
        val xOff = max(0f, abs(dx) - tol)
        val yOff = max(0f, abs(dy) - tol)
        if (xOff > 0f || yOff > 0f) {
            if (xOff >= yOff) return if (dx < 0) AimInstruction.MOVE_LEFT else AimInstruction.MOVE_RIGHT
            return if (dy < 0) AimInstruction.MOVE_UP else AimInstruction.MOVE_DOWN
        }
        if (max(b.width, b.height) < (if (loose) wholeLooseTooSmall else wholeTooSmall)) {
            return AimInstruction.MOVE_CLOSER
        }
        return AimInstruction.FRAMED
    }

    /**
     * Turns a box measured in the portrait camera buffer into the frame the
     * person is actually holding, [quarterTurns] x 90 degrees clockwise. Needed
     * so "move the phone up" still means up when the phone is held sideways.
     */
    fun rotateClockwise(box: AimRect, quarterTurns: Int): AimRect {
        var b = box
        repeat(((quarterTurns % 4) + 4) % 4) {
            // (x, y) -> (1 - y, x) for each point.
            b = AimRect(1 - b.maxY, b.minX, b.height, b.width)
        }
        return b
    }

    /**
     * Extra clockwise quarter turns to apply to a buffer that is already
     * rotated to portrait (90 degrees), given the rotation the display reports
     * for how the phone is held.
     */
    fun quarterTurns(levelAngle: Float): Int {
        val q = ((levelAngle - 90f) / 90f).roundToInt()
        return ((q % 4) + 4) % 4
    }
}

// MARK: - Phrases
//
// EVERY STRING HERE MUST MATCH iOS AimPhrases WORD FOR WORD.

object AimPhrases {
    fun phrase(instruction: AimInstruction, subject: AimSubject, faceCount: Int = 1): String =
        when (instruction) {
            AimInstruction.NOT_FOUND -> "I don't see ${subject.spokenName} yet, move the phone slowly"
            AimInstruction.MOVE_LEFT -> "move the phone left"
            AimInstruction.MOVE_RIGHT -> "move the phone right"
            AimInstruction.MOVE_UP -> "move the phone up"
            AimInstruction.MOVE_DOWN -> "move the phone down"
            AimInstruction.MOVE_CLOSER -> "move closer"
            AimInstruction.BACK_UP -> "back up"
            AimInstruction.BACK_UP_CUT_OFF ->
                if (subject is AimSubject.Page) "back up, the page is cut off" else "back up"
            AimInstruction.FRAMED ->
                if (subject is AimSubject.Face && faceCount > 1) {
                    "got it, ${countWord(faceCount)} faces, hold still"
                } else {
                    "got it, hold still"
                }
        }

    fun intro(subject: AimSubject): String =
        "Looking for ${subject.spokenName}. Move the phone slowly. Double tap anywhere to take the picture yourself."

    /**
     * What to say while it still hasn't found the thing, in the order it is
     * said.
     *
     * Matt, 2026-09-20, hearing the old version on Android: "it's not a lot to
     * repeat itself over and over like that. It has to be more informative and
     * user-friendly and nicer." It used to say ONE sentence every six seconds
     * forever, which reads as a stuck record when you cannot see the screen.
     * Now each turn says something different and adds a suggestion worth
     * acting on, and the last line settles into a calm, patient one rather
     * than nagging.
     */
    fun searching(step: Int, subject: AimSubject): String = when (step) {
        0 -> "I don't see ${subject.spokenName} yet, move the phone slowly"
        1 -> "still looking. try holding the phone a little further back"
        2 -> "still looking. turn slowly, a bit at a time, and give me a moment to catch up"
        3 -> "still looking. if the light is low, there's a flashlight button at the top of the screen"
        else -> "still looking for ${subject.spokenName}. take your time, i'll say the moment i see it"
    }

    const val lostIt = "lost it"
    const val pictureTaken = "picture taken"
    const val savedSuffix = ", saved to your photos"
    const val notSavedSuffix = ", but I couldn't save it. Allow adding photos in Settings"

    /** Said the moment the shot is kept, while the vision model looks at it. */
    const val describing = "picture taken. describing it"

    /** After the description is read out: where the photo went, with its words. */
    const val savedWithDescription = "saved to your photos with that description"
    const val notSavedWithDescription = "I couldn't save it. Allow adding photos in Settings"
    const val captureFailed = "I couldn't take the picture, try again"

    // Something Else, round 2 (Matt: "you don't know when to speak, if you need
    // to press the button, or hold it"). The app asks, beeps, and listens by
    // itself; Speak is a single tap for a retry.
    const val askWhat = "After the beep, say what you're looking for."
    const val heardNothing = "I didn't hear anything. Tap to Speak to try again, or type it."
    const val didntCatch = "I didn't catch that. Tap to Speak to try again."

    /** The retry button: one tap, nothing to hold. */
    const val speakTitle = "Tap to Speak"
    const val speakLabel = "Tap to speak"
    const val speakHint = "Then say what you're looking for after the beep"
    val countdown = listOf("3", "2", "1")

    fun cantLookFor(word: String): String {
        val w = word.trim()
        return if (w.isEmpty()) didntCatch else "I can't look for $w yet"
    }

    fun countWord(n: Int): String {
        val words = listOf(
            "zero", "one", "two", "three", "four", "five",
            "six", "seven", "eight", "nine", "ten",
        )
        return if (n in words.indices) words[n] else "many"
    }

    fun capitalized(s: String): String =
        if (s.isEmpty()) s else s.first().uppercase() + s.drop(1)
}

// MARK: - Listening timing and tones

object AimListening {
    /**
     * Wait this long after the prompt has finished before the beep, so the
     * microphone does not catch the tail of the sentence.
     */
    const val afterPrompt = 0.4

    /** Stop this long after the last new word. */
    const val silence = 1.3

    /** Nothing heard at all by then: give up. */
    const val noSpeech = 6.0

    /** Hard stop. */
    const val maxTotal = 9.0

    sealed class Result {
        data class Heard(val transcript: String) : Result()
        object Silence : Result()
        object NotUnderstood : Result()
    }

    fun shouldStop(heardSomething: Boolean, quiet: Double, total: Double): Boolean {
        if (total >= maxTotal) return true
        return if (heardSomething) quiet >= silence else total >= noSpeech
    }

    fun result(transcript: String, failed: Boolean): Result {
        val t = transcript.trim()
        if (t.isNotEmpty()) return Result.Heard(t)
        return if (failed) Result.NotUnderstood else Result.Silence
    }

    /** What to say for a listening result that did not become a search. */
    fun reply(result: Result): String? = when (result) {
        is Result.Heard -> null
        is Result.Silence -> AimPhrases.heardNothing
        is Result.NotUnderstood -> AimPhrases.didntCatch
    }
}

/**
 * Short generated beeps, so there is no doubt when to talk: two rising notes to
 * start, two falling notes when listening stops.
 */
object AimTones {
    val start = listOf(660.0, 990.0)
    val end = listOf(990.0, 660.0)
    const val noteSeconds = 0.09
    const val sampleRate = 44_100

    val duration: Double get() = noteSeconds * start.size

    /** 16-bit mono PCM WAV with a short fade on every note (no clicks). */
    fun wav(notes: List<Double>, noteSeconds: Double = AimTones.noteSeconds, volume: Double = 0.6): ByteArray {
        val perNote = (sampleRate * noteSeconds).toInt()
        val fade = max(1, perNote / 8)
        val samples = ShortArray(perNote * notes.size)
        var k = 0
        for (f in notes) {
            for (i in 0 until perNote) {
                val env = min(1.0, min(i, perNote - 1 - i).toDouble() / fade.toDouble())
                val v = sin(2 * Math.PI * f * i / sampleRate) * volume * env
                samples[k++] = (max(-1.0, min(1.0, v)) * Short.MAX_VALUE).toInt().toShort()
            }
        }
        val dataBytes = samples.size * 2
        val out = java.io.ByteArrayOutputStream(44 + dataBytes)
        fun u32(v: Int) {
            out.write(v and 0xFF); out.write((v ushr 8) and 0xFF)
            out.write((v ushr 16) and 0xFF); out.write((v ushr 24) and 0xFF)
        }
        fun u16(v: Int) { out.write(v and 0xFF); out.write((v ushr 8) and 0xFF) }
        out.write("RIFF".toByteArray()); u32(36 + dataBytes)
        out.write("WAVE".toByteArray())
        out.write("fmt ".toByteArray()); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        out.write("data".toByteArray()); u32(dataBytes)
        for (s in samples) u16(s.toInt() and 0xFFFF)
        return out.toByteArray()
    }
}

// MARK: - Coach (the state machine between the detector and the voice)

/**
 * Fed one observation per analysed frame; decides what to say, when the
 * countdown starts and when it is cancelled. No clocks or speech inside, so the
 * whole behaviour is testable.
 *
 * Round 2 rules (Matt's field test): judge a median of the last few boxes, not
 * the raw jittery one; a new steering instruction must hold for half a second
 * before it is spoken (no left/right flip-flop); once "got it" is said the
 * subject stays framed until it has been outside a much looser zone for 0.7 s;
 * and the countdown starts after the zone has simply been held for 0.4 s.
 */
class AimCoach(val subject: AimSubject) {
    enum class Haptic { NONE, TICK, SUCCESS, WARNING }

    sealed class Action {
        data class Say(val text: String, val haptic: Haptic) : Action()
        object StartCountdown : Action()
        object CancelCountdown : Action()
    }

    /** Same sentence again no sooner than this. */
    var repeatInterval = 2.5

    /** Gap after any sentence before a different one. */
    var minGap = 0.8

    /** "I don't see it yet" after this long with nothing found (Matt: 5 s)... */
    var notFoundAfter = 5.0

    /** ...and then no more often than this. */
    var notFoundRepeat = 6.0

    /**
     * After this long still not found, say what IS in view instead. Brought in
     * from 15 s (Matt, 2026-09-20: six identical lines before anything useful
     * was said) so the genuinely informative sentence arrives on the second
     * turn rather than the fourth.
     */
    var elsewhereAfter = 10.0

    /** ...at most this often... */
    var elsewhereRepeat = 12.0

    /** ...and not closer than this to the previous "I don't see" line. */
    var elsewhereGap = 3.0

    /** A box that blinks out for less than this still counts as there. */
    var holdLastBox = 0.6

    /** A new steering instruction must stay the same this long to be spoken. */
    var settle = 0.5

    /** Framed must hold this long before "got it". */
    var framedSettle = 0.3

    /** After "got it", the zone held this long starts the countdown. */
    var steadyFor = 0.4

    /** Moving more than this (share of the frame) restarts the steady clock. */
    var steadyDrift = 0.15f

    /** Outside the loose zone this long undoes "got it" / cancels the countdown. */
    var leaveAfter = 0.7

    /** Boxes in the median. */
    var smoothingWindow = 5

    /** Reversing the last direction within [flipWindow] must hold this long. */
    var flipSettle = 1.2
    var flipWindow = 3.0

    /**
     * Pages: this many direction lines, at least [bounceKinds] different, inside
     * [bounceWindow] means it's too big or too close: say "back up" instead of
     * another direction (walkaround 2026-09-16, a wall map).
     */
    var bounceLines = 4
    var bounceKinds = 3
    var bounceWindow = 8.0

    /** After that "back up", no direction lines for this long. */
    var bounceQuiet = 2.5

    var isCountingDown = false
        private set
    var isLocked = false
        private set
    var smoothedBox: AimRect? = null
        private set

    private val recent = ArrayList<Pair<Double, AimRect>>()
    private var lastSeen: Double? = null
    private var startedAt: Double? = null
    private var lastPhrase: String? = null
    private var lastSpokenAt = DISTANT_PAST

    /** Last "I don't see..." line of either kind, and of the long kind. */
    private var lastMissAt = DISTANT_PAST
    private var lastElsewhereAt = DISTANT_PAST

    /** Which rung of the "still looking" ladder comes next. */
    private var missStep = 0
    private var candidate: AimInstruction? = null
    private var candidateSince = DISTANT_PAST
    private var lockedAt = DISTANT_PAST
    private var anchor: AimPoint? = null
    private var outSince: Double? = null
    private val directions = ArrayList<Pair<Double, AimInstruction>>()
    private var bouncedAt = DISTANT_PAST

    /** Start over (a new aim, or back from the background). */
    fun reset(now: Double) {
        countdownEnded()
        smoothedBox = null
        recent.clear()
        lastSeen = null
        startedAt = now
        lastPhrase = null
        lastSpokenAt = DISTANT_PAST
        lastMissAt = DISTANT_PAST
        lastElsewhereAt = DISTANT_PAST
        missStep = 0
        directions.clear()
        bouncedAt = DISTANT_PAST
    }

    /**
     * The controller cancelled or finished the countdown itself. "Got it" has to
     * be earned again, not said on the very next frame.
     */
    fun countdownEnded() {
        isCountingDown = false
        isLocked = false
        anchor = null
        outSince = null
        candidate = null
        candidateSince = DISTANT_PAST
    }

    /**
     * [elsewhere] is the ready "I don't see X. I can see ..." sentence for this
     * frame, or null when nothing else was looked for (faces).
     */
    fun observe(
        raw: AimRect?,
        faceCount: Int = 1,
        now: Double,
        voiceBusy: Boolean,
        elsewhere: String? = null,
    ): List<Action> {
        if (startedAt == null) startedAt = now
        val box = track(raw, now)
        val inLooseZone =
            AimSteering.instruction(box, subject.framing, loose = true) == AimInstruction.FRAMED

        if (isCountingDown) {
            if (inLooseZone) { outSince = null; return emptyList() }
            val since = outSince ?: now
            outSince = since
            if (now - since + EPS < leaveAfter) return emptyList()
            countdownEnded()
            lastPhrase = AimPhrases.lostIt
            lastSpokenAt = now
            return listOf(Action.CancelCountdown, Action.Say(AimPhrases.lostIt, Haptic.WARNING))
        }

        if (isLocked) {
            if (inLooseZone && box != null) {
                outSince = null
                val center = AimPoint(box.midX, box.midY)
                val a = anchor
                if (a != null && hypot((center.x - a.x).toDouble(), (center.y - a.y).toDouble()) <= steadyDrift) {
                    if (raw != null && !voiceBusy && now - lockedAt + EPS >= steadyFor) {
                        isCountingDown = true
                        return listOf(Action.StartCountdown)
                    }
                } else {
                    anchor = center
                    lockedAt = now
                }
                return emptyList()
            }
            val since = outSince ?: now
            outSince = since
            if (now - since + EPS < leaveAfter) return emptyList()
            // Really gone: back to steering.
            countdownEnded()
        }

        val instruction = AimSteering.instruction(box, subject.framing)
        if (instruction != candidate) {
            candidate = instruction
            candidateSince = now
        }

        if (instruction == AimInstruction.NOT_FOUND) {
            val since = lastSeen ?: startedAt ?: now
            val lost = now - since + EPS
            if (lost < notFoundAfter) return emptyList()
            val quiet = now - lastSpokenAt + EPS
            if (voiceBusy || quiet < minGap) return emptyList()
            val sinceMiss = now - lastMissAt + EPS
            val text: String
            if (elsewhere != null && lost >= elsewhereAfter && sinceMiss >= elsewhereGap &&
                now - lastElsewhereAt + EPS >= elsewhereRepeat
            ) {
                text = elsewhere
                lastElsewhereAt = now
            } else if (sinceMiss >= notFoundRepeat) {
                // Never the same sentence twice in a row: walk the ladder.
                text = AimPhrases.searching(missStep, subject)
                missStep++
            } else {
                return emptyList()
            }
            lastMissAt = now
            lastPhrase = text
            lastSpokenAt = now
            return listOf(Action.Say(text, Haptic.NONE))
        } else {
            var wait = if (instruction == AimInstruction.FRAMED) framedSettle else settle
            val last = directions.lastOrNull()
            if (last != null && isReversal(last.second, instruction) && now - last.first < flipWindow) {
                wait = flipSettle
            }
            if (now - candidateSince + EPS < wait) return emptyList()
        }

        val quiet = now - lastSpokenAt + EPS
        if (voiceBusy || quiet < minGap) return emptyList()

        if (instruction == AimInstruction.FRAMED && box != null) {
            val text = AimPhrases.phrase(AimInstruction.FRAMED, subject, faceCount)
            isLocked = true
            lockedAt = now // the steady clock starts after the sentence begins
            anchor = AimPoint(box.midX, box.midY)
            outSince = null
            lastPhrase = text
            lastSpokenAt = now
            return listOf(Action.Say(text, Haptic.SUCCESS))
        }

        var spoken = instruction
        if (isDirection(instruction)) {
            if (now - bouncedAt < bounceQuiet) return emptyList()
            directions.removeAll { now - it.first > bounceWindow }
            if (subject.framing == AimSteering.Framing.PAGE && directions.size + 1 >= bounceLines &&
                (directions.map { it.second } + instruction).toSet().size >= bounceKinds
            ) {
                spoken = AimInstruction.BACK_UP
                directions.clear()
                bouncedAt = now
            }
        }
        val text = AimPhrases.phrase(spoken, subject, faceCount)
        if (text == lastPhrase && quiet < repeatInterval) return emptyList()
        if (isDirection(spoken)) directions.add(now to spoken)
        lastPhrase = text
        lastSpokenAt = now
        return listOf(Action.Say(text, Haptic.TICK))
    }

    /**
     * Median of the last few boxes (per edge), so detector jitter and hand shake
     * do not flip the instruction; a short dropout keeps the last box.
     */
    private fun track(raw: AimRect?, now: Double): AimRect? {
        if (raw != null) {
            lastSeen = now
            recent.add(now to raw)
            recent.removeAll { now - it.first > 1.0 }
            while (recent.size > smoothingWindow) recent.removeAt(0)
            smoothedBox = median(recent.map { it.second })
            return smoothedBox
        }
        val seen = lastSeen
        if (seen != null && now - seen <= holdLastBox + EPS) return smoothedBox
        recent.clear()
        smoothedBox = null
        return null
    }

    companion object {
        private const val EPS = 1e-6
        private const val DISTANT_PAST = -1.0e12

        fun isDirection(i: AimInstruction): Boolean = i == AimInstruction.MOVE_LEFT ||
            i == AimInstruction.MOVE_RIGHT || i == AimInstruction.MOVE_UP || i == AimInstruction.MOVE_DOWN

        fun isReversal(a: AimInstruction, b: AimInstruction): Boolean =
            (a == AimInstruction.MOVE_LEFT && b == AimInstruction.MOVE_RIGHT) ||
                (a == AimInstruction.MOVE_RIGHT && b == AimInstruction.MOVE_LEFT) ||
                (a == AimInstruction.MOVE_UP && b == AimInstruction.MOVE_DOWN) ||
                (a == AimInstruction.MOVE_DOWN && b == AimInstruction.MOVE_UP)

        fun median(boxes: List<AimRect>): AimRect? {
            if (boxes.isEmpty()) return null
            fun mid(values: List<Float>): Float {
                val s = values.sorted()
                return if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2f
            }
            return AimRect.fromEdges(
                mid(boxes.map { it.minX }), mid(boxes.map { it.minY }),
                mid(boxes.map { it.maxX }), mid(boxes.map { it.maxY }),
            )
        }
    }
}

// MARK: - Burst pick and crop

/**
 * Round 2: the countdown ends in a short burst; the detector runs on every
 * frame and the best-framed one is kept, then cropped so the subject sits where
 * a photographer would put it ("shoot wide, crop after").
 */
object AimBurst {
    data class Frame(
        /** Subject box, normalized, top-left origin, upright photo. */
        val box: AimRect?,
        /** Variance of Laplacian (higher is sharper). */
        val sharpness: Double,
    )

    /** Sharpness above this earns no more credit. */
    const val sharpnessCap = 300.0
    const val sharpnessWeight = 0.3
    const val cutOffPenalty = 1.0

    /**
     * Higher is better; null when the subject is not in the frame.
     * 1 - 2 x (distance from the framing target) - 1 if cut off
     *   + 0.3 x min(sharpness, 300) / 300.
     */
    fun score(f: Frame, framing: AimSteering.Framing): Double? {
        val b = f.box ?: return null
        if (b.width <= 0f || b.height <= 0f) return null
        val t = AimSteering.target(b, framing)
        val distance = hypot((b.midX - t.x).toDouble(), (b.midY - t.y).toDouble())
        var s = 1 - 2 * distance
        if (AimSteering.isCutOff(b)) s -= cutOffPenalty
        s += sharpnessWeight * min(max(f.sharpness, 0.0), sharpnessCap) / sharpnessCap
        return s
    }

    /**
     * Index of the frame to keep: the best score, or the sharpest frame if the
     * subject is in none of them. Null only for an empty burst.
     */
    fun pick(frames: List<Frame>, framing: AimSteering.Framing): Int? {
        if (frames.isEmpty()) return null
        val sharpest = frames
            .filter { f -> f.box?.let { !AimSteering.isCutOff(it) } ?: false }
            .maxOfOrNull { it.sharpness } ?: 0.0
        val scored = frames.mapIndexedNotNull { i, f ->
            val b = f.box
            if (b != null && !AimSteering.isCutOff(b) && f.sharpness < sharpest * minRelativeSharpness) {
                null
            } else {
                score(f, framing)?.let { i to it }
            }
        }
        val best = scored.maxByOrNull { it.second }
        if (best != null) return best.first
        return frames.indices.maxByOrNull { frames[it].sharpness }
    }

    /** Never crop to less than this on the long side. */
    const val minLongSide = 2000f

    /**
     * Share of the crop the subject should fill (its bigger dimension): objects
     * about half (25% padding each side), a face about a third so there is room
     * for shoulders.
     */
    const val objectFill = 0.5f
    const val faceFill = 0.35f

    /**
     * A big or far-off-centre object gets moved to the middle with as little as
     * this much padding (Kareen, 2026-09-25).
     */
    const val bigObjectFill = 0.9f

    /** Already this close to the target and at least this big: leave it. */
    const val wellFramedDistance = 0.08f
    const val wellFramedSize = 0.4f

    /** The largest crop (share of each side) used to lift a big face. */
    const val maxFaceCropShare = 0.85f

    /**
     * A framed frame this much softer than the sharpest framed one in the burst
     * is dropped (walkaround 2026-09-16: a motion-blurred page shot won because
     * the sharpness credit caps far below real values).
     */
    const val minRelativeSharpness = 0.7

    /**
     * The crop rectangle in pixels (top-left origin), or null to keep the whole
     * photo. Same aspect ratio as the photo.
     */
    fun crop(box: AimRect, imageWidth: Float, imageHeight: Float, framing: AimSteering.Framing): AimRect? {
        val w = imageWidth
        val h = imageHeight
        if (w <= 0f || h <= 0f || box.width <= 0f || box.height <= 0f || max(w, h) <= minLongSide) return null
        // Subject cut off in the photo: cropping cannot bring it back.
        if (AimSteering.isCutOff(box)) return null
        val t = AimSteering.target(box, framing)
        val size = max(box.width, box.height)
        if (hypot((box.midX - t.x).toDouble(), (box.midY - t.y).toDouble()) <= wellFramedDistance &&
            size >= wellFramedSize
        ) return null

        var fill = if (framing == AimSteering.Framing.PERSON && box.height < AimSteering.closeUpFull) {
            faceFill
        } else {
            objectFill
        }
        if (framing != AimSteering.Framing.PERSON) {
            // Kareen, 2026-09-25: a big or far-off-centre subject stayed off to
            // one side because the usual padding left no room to slide it. Use
            // just enough less padding (down to bigObjectFill) for the crop to
            // put it in the middle.
            val room = 1f - 2f * max(abs(box.midX - 0.5f), abs(box.midY - 0.5f))
            val needed = if (room > 0f) max(box.width, box.height) / room else bigObjectFill
            fill = min(bigObjectFill, max(fill, needed))
        }
        val aspect = w / h
        val bw = box.width * w
        val bh = box.height * h
        var cw = max(bw / fill, (bh / fill) * aspect)
        var ch = cw / aspect
        // Keep enough pixels.
        val long = max(cw, ch)
        if (long < minLongSide) {
            val k = minLongSide / long
            cw *= k; ch *= k
        }
        var mustImprove = false
        if (cw >= w * 0.98f || ch >= h * 0.98f) {
            // A face too big for the usual padding (walkaround 2026-09-16: a
            // selfie face at 35% of the width was never cropped and stayed
            // mid-frame). Still trim a little to lift it toward the upper third,
            // but only if that really moves it closer. An object is already at
            // the least padding, so there is nothing left to slide.
            if (framing != AimSteering.Framing.PERSON) return null
            cw = w * maxFaceCropShare
            ch = h * maxFaceCropShare
            mustImprove = true
        }

        // Put the subject's middle at the target point, then keep inside the photo.
        var x = box.midX * w - t.x * cw
        var y = box.midY * h - t.y * ch
        x = min(max(0f, x), w - cw)
        y = min(max(0f, y), h - ch)
        val integral = AimRect(
            kotlin.math.floor(x), kotlin.math.floor(y),
            kotlin.math.ceil(cw), kotlin.math.ceil(ch),
        )
        val rect = integral.intersection(AimRect(0f, 0f, w, h)) ?: return null
        val subject = AimRect(box.minX * w, box.minY * h, bw, bh)
        val inset = subject.insetBy(1f, 1f)
        val contains = rect.minX <= inset.minX && rect.minY <= inset.minY &&
            rect.maxX >= inset.maxX && rect.maxY >= inset.maxY
        if (!contains) return null
        if (mustImprove || (framing == AimSteering.Framing.PERSON && cw >= w * maxFaceCropShare - 1f)) {
            val before = hypot((box.midX - t.x).toDouble(), (box.midY - t.y).toDouble())
            val after = hypot(
                ((subject.midX - rect.minX) / rect.width - t.x).toDouble(),
                ((subject.midY - rect.minY) / rect.height - t.y).toDouble(),
            )
            if (after >= before - 0.03) return null
        }
        return rect
    }
}

// MARK: - Squaring up a picture or page

/**
 * Four corners of a picture or page, normalized, top-left origin, upright
 * photo. Clockwise from the top-left.
 */
data class AimQuad(
    val topLeft: AimPoint,
    val topRight: AimPoint,
    val bottomRight: AimPoint,
    val bottomLeft: AimPoint,
) {
    val corners get() = listOf(topLeft, topRight, bottomRight, bottomLeft)
}

/**
 * Kareen (Blind Android Users, 2026-09-25): "a photo frame was taken at an
 * angle instead of being in the centre of the photo." When Picture or Page
 * found the page's four corners, the kept photo is the page itself, squared
 * up, instead of a tilted page in a wider shot. Only when the corners make a
 * believable page; otherwise the normal crop runs. Same rules as the iPhone.
 */
object AimStraighten {
    /** Smaller than this share of the photo: too small to be the page asked for. */
    const val minArea = 0.04f

    /** A corner this close to the photo edge may be cut off. */
    const val cornerMargin = 0.005f

    /**
     * Every corner angle inside this range (degrees); outside it the corners are
     * not a page seen at a normal angle.
     */
    const val minAngle = 45f
    const val maxAngle = 135f

    /** Opposite sides this different in length: too steep to square up well. */
    const val maxSideRatio = 2.5f

    fun area(q: AimQuad): Float {
        val p = q.corners
        var a = 0f
        for (i in 0 until 4) {
            val j = (i + 1) % 4
            a += p[i].x * p[j].y - p[j].x * p[i].y
        }
        return abs(a) / 2f
    }

    fun distance(a: AimPoint, b: AimPoint, w: Float, h: Float): Float =
        hypot(((a.x - b.x) * w).toDouble(), ((a.y - b.y) * h).toDouble()).toFloat()

    /** True when the corners are a page worth squaring up in a [w] x [h] photo. */
    fun usable(q: AimQuad?, w: Float, h: Float): Boolean {
        if (q == null || w <= 0f || h <= 0f) return false
        val p = q.corners
        if (p.any { it.x < cornerMargin || it.y < cornerMargin || it.x > 1 - cornerMargin || it.y > 1 - cornerMargin }) {
            return false
        }
        if (area(q) < minArea) return false
        // Convex, and clockwise on screen (y down): every turn the same way.
        var sign = 0
        for (i in 0 until 4) {
            val a = p[i]
            val b = p[(i + 1) % 4]
            val c = p[(i + 2) % 4]
            val cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if (abs(cross) < 1e-9f) return false
            val s = if (cross > 0) 1 else -1
            if (sign == 0) sign = s else if (s != sign) return false
        }
        if (sign < 0) return false
        // Corner angles, measured in pixels so a portrait photo is not skewed.
        for (i in 0 until 4) {
            val prev = p[(i + 3) % 4]
            val c = p[i]
            val next = p[(i + 1) % 4]
            val ux = (prev.x - c.x) * w
            val uy = (prev.y - c.y) * h
            val vx = (next.x - c.x) * w
            val vy = (next.y - c.y) * h
            val len = max(1e-9, hypot(ux.toDouble(), uy.toDouble()) * hypot(vx.toDouble(), vy.toDouble()))
            val cosA = ((ux * vx + uy * vy) / len).coerceIn(-1.0, 1.0)
            val deg = Math.toDegrees(kotlin.math.acos(cosA)).toFloat()
            if (deg < minAngle || deg > maxAngle) return false
        }
        val top = distance(q.topLeft, q.topRight, w, h)
        val bottom = distance(q.bottomLeft, q.bottomRight, w, h)
        val left = distance(q.topLeft, q.bottomLeft, w, h)
        val right = distance(q.topRight, q.bottomRight, w, h)
        if (min(top, bottom) <= 0f || min(left, right) <= 0f) return false
        return max(top, bottom) / min(top, bottom) <= maxSideRatio &&
            max(left, right) / min(left, right) <= maxSideRatio
    }

    /**
     * Pixel size of the squared-up page: its longest top/bottom side by its
     * longest left/right side, never bigger than the photo.
     */
    fun outputSize(q: AimQuad, w: Float, h: Float): Pair<Float, Float> {
        var ow = max(distance(q.topLeft, q.topRight, w, h), distance(q.bottomLeft, q.bottomRight, w, h))
        var oh = max(distance(q.topLeft, q.bottomLeft, w, h), distance(q.topRight, q.bottomRight, w, h))
        val k = min(1f, max(w, h) / max(max(ow, oh), 1f))
        ow *= k
        oh *= k
        return Pair(max(1f, ow.roundToInt().toFloat()), max(1f, oh.roundToInt().toFloat()))
    }
}

/**
 * Android has no document finder like Apple's Vision (see AimVision.pageBox),
 * so Picture or Page finds the page's four edges itself, near the sides of the
 * box the detector gave: strong edges in a band along each side, a straight
 * line fitted through them, and the corners where the lines meet. Pure
 * arithmetic on a grayscale copy, so it is unit tested without a camera.
 */
object AimQuadFinder {
    /** Long side of the grayscale copy it looks at. */
    const val analysisSide = 640

    /** Each side's search band reaches this share of the box inward... */
    const val bandIn = 0.25f

    /** ...and this share outward. */
    const val bandOut = 0.08f

    /** Gradient strength (0-255 gray, Sobel) that counts as an edge. */
    const val minEdge = 60f

    /** An edge this much more along the side than across it belongs to it. */
    const val orientationLead = 1.5f

    /** Pixels from the line that still count as on it. */
    const val inlierDistance = 2f

    /** Share of the side's length the line has to be seen along. */
    const val minCoverage = 0.4f

    const val iterations = 200

    private class Line(val a: Float, val c: Float)

    /** Corners, normalized, or null when any of the four edges is unclear. */
    fun find(gray: FloatArray, w: Int, h: Int, box: AimRect): AimQuad? {
        if (w < 8 || h < 8 || gray.size < w * h) return null
        val bx0 = box.minX * w
        val bx1 = box.maxX * w
        val by0 = box.minY * h
        val by1 = box.maxY * h
        val bw = bx1 - bx0
        val bh = by1 - by0
        if (bw < 8f || bh < 8f) return null
        val gx = FloatArray(w * h)
        val gy = FloatArray(w * h)
        for (y in 1 until h - 1) {
            for (x in 1 until w - 1) {
                val i = y * w + x
                gx[i] = (gray[i - w + 1] + 2 * gray[i + 1] + gray[i + w + 1]) -
                    (gray[i - w - 1] + 2 * gray[i - 1] + gray[i + w - 1])
                gy[i] = (gray[i + w - 1] + 2 * gray[i + w] + gray[i + w + 1]) -
                    (gray[i - w - 1] + 2 * gray[i - w] + gray[i - w + 1])
            }
        }
        val top = side(gx, gy, w, h, horizontal = true, along0 = bx0 - bandOut * bw, along1 = bx1 + bandOut * bw,
            across0 = by0 - bandOut * bh, across1 = by0 + bandIn * bh, length = bw) ?: return null
        val bottom = side(gx, gy, w, h, horizontal = true, along0 = bx0 - bandOut * bw, along1 = bx1 + bandOut * bw,
            across0 = by1 - bandIn * bh, across1 = by1 + bandOut * bh, length = bw) ?: return null
        val left = side(gx, gy, w, h, horizontal = false, along0 = by0 - bandOut * bh, along1 = by1 + bandOut * bh,
            across0 = bx0 - bandOut * bw, across1 = bx0 + bandIn * bw, length = bh) ?: return null
        val right = side(gx, gy, w, h, horizontal = false, along0 = by0 - bandOut * bh, along1 = by1 + bandOut * bh,
            across0 = bx1 - bandIn * bw, across1 = bx1 + bandOut * bw, length = bh) ?: return null
        fun corner(hz: Line, vt: Line): AimPoint? {
            // y = hz.a * x + hz.c and x = vt.a * y + vt.c
            val d = 1f - hz.a * vt.a
            if (abs(d) < 1e-6f) return null
            val x = (vt.a * hz.c + vt.c) / d
            val y = hz.a * x + hz.c
            return AimPoint(x / w, y / h)
        }
        val q = AimQuad(
            corner(top, left) ?: return null,
            corner(top, right) ?: return null,
            corner(bottom, right) ?: return null,
            corner(bottom, left) ?: return null,
        )
        // The corners must sit near the box they were looked for around.
        val slackX = bandOut * box.width
        val slackY = bandOut * box.height
        if (q.corners.any {
                it.x < box.minX - slackX || it.x > box.maxX + slackX ||
                    it.y < box.minY - slackY || it.y > box.maxY + slackY
            }
        ) return null
        return q
    }

    /**
     * One edge. Horizontal sides are y = a·x + c (along = x, across = y);
     * vertical sides are x = a·y + c (along = y, across = x).
     */
    private fun side(
        gx: FloatArray, gy: FloatArray, w: Int, h: Int, horizontal: Boolean,
        along0: Float, along1: Float, across0: Float, across1: Float, length: Float,
    ): Line? {
        val alongMax = if (horizontal) w - 2 else h - 2
        val acrossMax = if (horizontal) h - 2 else w - 2
        val a0 = max(1, along0.toInt())
        val a1 = min(alongMax, along1.toInt())
        val c0 = max(1, across0.toInt())
        val c1 = min(acrossMax, across1.toInt())
        if (a1 <= a0 || c1 <= c0) return null
        val ptsAlong = ArrayList<Float>()
        val ptsAcross = ArrayList<Float>()
        for (u in a0..a1) {
            for (v in c0..c1) {
                val i = if (horizontal) v * w + u else u * w + v
                val across = abs(if (horizontal) gy[i] else gx[i])
                val alongG = abs(if (horizontal) gx[i] else gy[i])
                if (across >= minEdge && across >= orientationLead * alongG) {
                    ptsAlong.add(u.toFloat())
                    ptsAcross.add(v.toFloat())
                }
            }
        }
        val n = ptsAlong.size
        if (n < 2) return null
        val rng = java.util.Random(7)
        var bestA = 0f
        var bestC = 0f
        var bestCount = -1
        repeat(iterations) {
            val i = rng.nextInt(n)
            val j = rng.nextInt(n)
            val du = ptsAlong[j] - ptsAlong[i]
            if (abs(du) < length * 0.1f) return@repeat
            val a = (ptsAcross[j] - ptsAcross[i]) / du
            if (abs(a) > 0.7f) return@repeat
            val c = ptsAcross[i] - a * ptsAlong[i]
            var count = 0
            for (k in 0 until n) if (abs(a * ptsAlong[k] + c - ptsAcross[k]) <= inlierDistance) count++
            if (count > bestCount) {
                bestCount = count
                bestA = a
                bestC = c
            }
        }
        if (bestCount < 2) return null
        // Least squares on the inliers, and how much of the side they cover.
        var su = 0.0
        var sv = 0.0
        var suu = 0.0
        var suv = 0.0
        var m = 0
        val covered = BooleanArray(a1 - a0 + 1)
        for (k in 0 until n) {
            if (abs(bestA * ptsAlong[k] + bestC - ptsAcross[k]) <= inlierDistance) {
                val u = ptsAlong[k].toDouble()
                val v = ptsAcross[k].toDouble()
                su += u; sv += v; suu += u * u; suv += u * v; m++
                covered[ptsAlong[k].toInt() - a0] = true
            }
        }
        if (covered.count { it } < minCoverage * length) return null
        val den = m * suu - su * su
        if (m < 2 || abs(den) < 1e-9) return Line(bestA, bestC)
        val a = ((m * suv - su * sv) / den).toFloat()
        val c = ((sv - a * su) / m).toFloat()
        return Line(a, c)
    }
}

// MARK: - Which rectangle is the page

/**
 * Picture or Page picks its box here (walkaround 2026-09-16: it locked onto a
 * small white box on a table next to a moving cat, and onto bits of a wall map).
 * The document finder wins when it is sure; otherwise a rectangle only counts if
 * it looks like paper (bright, not colourful) or the detector agrees there is a
 * page, picture or poster in the same place.
 */
object AimPage {
    data class Candidate(
        /** Normalized, top-left origin. */
        val box: AimRect,
        val documentLike: Boolean,
    )

    const val minDocumentConfidence = 0.6f
    const val minDocumentArea = 0.03f
    const val minBrightness = 0.40f
    const val maxSaturation = 0.25f

    /** Average colour of the rectangle, 0..1 per channel. */
    fun isDocumentLike(red: Float, green: Float, blue: Float): Boolean {
        val luma = 0.299f * red + 0.587f * green + 0.114f * blue
        val saturation = max(max(red, green), blue) - min(min(red, green), blue)
        return luma >= minBrightness && saturation <= maxSaturation
    }

    fun area(r: AimRect): Float = r.width * r.height

    /** Same thing: they overlap by a third, or one holds the other's middle. */
    fun sameThing(a: AimRect, b: AimRect): Boolean {
        val i = a.intersection(b) ?: return false
        if (i.width <= 0f || i.height <= 0f) return false
        val iou = area(i) / (area(a) + area(b) - area(i))
        return iou >= 0.3f || a.contains(b.midX, b.midY) || b.contains(a.midX, a.midY)
    }

    fun choose(document: AimRect?, rectangles: List<Candidate>, backup: AimRect?): AimRect? {
        if (document != null) return document
        val supported = rectangles.filter { c ->
            c.documentLike || (backup != null && sameThing(c.box, backup))
        }
        val best = supported.maxByOrNull { area(it.box) }?.box ?: return backup
        // The rectangle finder misses a page that runs off the edge; the model
        // still sees that one, so take the model's bigger box then.
        if (backup != null && sameThing(best, backup) && area(backup) > area(best)) return backup
        return best
    }
}

// MARK: - How the phone is held

/**
 * Which way the still is turned (walkaround 2026-09-16: with the phone flat over
 * a table the level-shot angle is a guess). The app is portrait-only, so
 * portrait unless gravity clearly says the phone is on its side.
 */
object AimHold {
    const val portraitAngle = 90f

    /** |z| above this: lying flat (face up or down). */
    const val flatZ = 0.75

    /** |x| above this, and clearly more than |y|: on its side. */
    const val sidewaysX = 0.6
    const val sidewaysLead = 0.25

    fun isClearlyLandscape(x: Double, y: Double, z: Double): Boolean =
        abs(z) < flatZ && abs(x) > sidewaysX && abs(x) > abs(y) + sidewaysLead

    /**
     * [levelAngle] from the display rotation; gravity in g, null if unknown.
     * On Android gravity comes from TYPE_GRAVITY in m/s^2, so divide by 9.81
     * before calling.
     */
    fun captureAngle(levelAngle: Float?, gravity: Triple<Double, Double, Double>?): Float {
        if (levelAngle == null || gravity == null ||
            !isClearlyLandscape(gravity.first, gravity.second, gravity.third)
        ) {
            return portraitAngle
        }
        val a = levelAngle % 360f
        // Only a landscape answer is trusted here.
        return if (abs(a) < 1f || abs(a - 180f) < 1f) a else portraitAngle
    }
}
