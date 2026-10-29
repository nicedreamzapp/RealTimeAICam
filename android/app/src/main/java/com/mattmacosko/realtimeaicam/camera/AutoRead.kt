package com.mattmacosko.realtimeaicam.camera

/**
 * The text reader's speech mode (Matt, 2026-10-23): one small button next to Speak cycles
 * these, and the choice is remembered.
 *  - TAP:  today's behavior. Nothing is read until Speak is tapped.
 *  - AUTO: new, steady text is read by itself (like Object Detection names what it sees).
 *  - MUTE: text on screen only, nothing said by itself. Speak still works when tapped.
 */
enum class ReadingMode(val key: String, val label: String) {
    TAP("tap", "Tap to read"),
    AUTO("auto", "Auto read"),
    MUTE("mute", "Mute");

    val next: ReadingMode get() = entries[(ordinal + 1) % entries.size]

    companion object {
        const val PREF_KEY = "readingMode"
        fun fromKey(key: String?): ReadingMode = entries.firstOrNull { it.key == key } ?: TAP
    }
}

/**
 * Auto read's rules, kept apart from the camera so they can be unit tested. Live OCR jitters:
 * a letter flips, a line drops out of the frame and comes back. Reading every change would
 * chatter, so a page is read only when
 *  - it has held steady (any reading similar to the last one counts as the same) for [stableMs];
 *  - it is genuinely new: not similar to, and not just a piece of, anything read in the last
 *    [repeatWindowMs] (the same spirit as Object Detection's 45 s per-name cooldown);
 *  - nothing is being said right now ([due]'s busy flag). A new page waits for the current
 *    sentence to finish; it never cuts it off.
 * Times are in milliseconds from any monotonic clock.
 */
class AutoReadGate(
    private val stableMs: Long = 1_000L,
    private val repeatWindowMs: Long = 45_000L,
) {
    private companion object {
        const val SAME_READING = 0.75   // two OCR passes over the same page
        const val ALREADY_SAID = 0.80   // close enough to something already read
        const val PART_OF = 0.90        // share of a reading's letter pairs found in another
        const val MIN_CHARS = 3
        const val HISTORY = 8
    }

    private var pendingRaw: String? = null
    private var pendingNorm = ""
    private var pendingSince = 0L
    private val spoken = ArrayDeque<Pair<String, Long>>() // normalized text, when it was read

    /** Feed the text currently on screen (call on every change, or on a steady tick). */
    fun observe(text: String, now: Long) {
        val norm = normalize(text)
        if (norm.count { it.isLetterOrDigit() } < MIN_CHARS) return
        val current = pendingRaw
        if (current != null && sameReading(norm, pendingNorm)) {
            // Same page, jittered. Keep the fuller of the two readings; keep the clock running.
            if (norm.length >= pendingNorm.length * 0.8) {
                pendingRaw = text
                pendingNorm = norm
            }
            return
        }
        pendingRaw = text
        pendingNorm = norm
        pendingSince = now
    }

    /** The text to read now, or null. Call [markSpoken] once it has been handed to the voice. */
    fun due(now: Long, busy: Boolean): String? {
        val raw = pendingRaw ?: return null
        if (busy || now - pendingSince < stableMs) return null
        spoken.removeAll { now - it.second > repeatWindowMs }
        if (spoken.any { alreadySaid(pendingNorm, it.first) }) return null
        return raw
    }

    /** Something was read (by Auto or by the Speak button): don't read it again soon. */
    fun markSpoken(text: String, now: Long) {
        val norm = normalize(text)
        if (norm.isEmpty()) return
        spoken.addLast(norm to now)
        while (spoken.size > HISTORY) spoken.removeFirst()
    }

    /** Clear and stop / new scan: start fresh. */
    fun reset() {
        pendingRaw = null
        pendingNorm = ""
        pendingSince = 0L
        spoken.clear()
    }

    private fun sameReading(a: String, b: String): Boolean =
        dice(a, b) >= SAME_READING || partOf(a, b) || partOf(b, a)

    private fun alreadySaid(candidate: String, said: String): Boolean =
        dice(candidate, said) >= ALREADY_SAID || containment(candidate, said) >= PART_OF

    /** [a] is mostly inside [b] and at least half its size (a line dropped out of the frame). */
    private fun partOf(a: String, b: String): Boolean =
        a.length >= b.length / 2 && containment(a, b) >= PART_OF

    // ---- Letter-pair similarity: linear time, forgiving of single-letter OCR flips ----

    fun normalize(text: String): String =
        text.lowercase()
            .map { if (it.isLetterOrDigit()) it else ' ' }
            .joinToString("")
            .trim()
            .replace(Regex("\\s+"), " ")

    private fun bigrams(s: String): HashMap<Int, Int> {
        val m = HashMap<Int, Int>()
        for (i in 0 until s.length - 1) {
            val k = (s[i].code shl 16) or s[i + 1].code
            m[k] = (m[k] ?: 0) + 1
        }
        return m
    }

    private fun overlap(a: Map<Int, Int>, b: Map<Int, Int>): Int =
        a.entries.sumOf { (k, n) -> minOf(n, b[k] ?: 0) }

    fun dice(a: String, b: String): Double {
        if (a == b) return 1.0
        val ba = bigrams(a); val bb = bigrams(b)
        val total = ba.values.sum() + bb.values.sum()
        return if (total == 0) 0.0 else 2.0 * overlap(ba, bb) / total
    }

    /** Share of [a]'s letter pairs that also appear in [b]. */
    fun containment(a: String, b: String): Double {
        val ba = bigrams(a)
        val n = ba.values.sum()
        return if (n == 0) 0.0 else overlap(ba, bigrams(b)).toDouble() / n
    }
}
