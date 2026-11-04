package com.mattmacosko.realtimeaicam.narrator

/**
 * The pure text rules around a What's this? answer, kept apart so they can be unit tested.
 *
 * 2026-11-04, the Cricket (Helio P35): one dim photo took 456 s and ended "…I think I can make
 * out it's just a blurry." The model's honest "it's hard to see, but…" answer was read as a
 * refusal, so all four passes ran at ~110 s each, and the last one glued a broken clause into
 * the noun list. These rules keep a describing answer, only retry when a retry fits in the
 * time budget, and never let a sentence end in the middle.
 */
object AnswerText {

    /**
     * Retries only while the whole chain stays under this many seconds. A phone that answers
     * in ~10 s still gets every pass; a phone that needs ~100 s for one gets just the one.
     */
    const val RETRY_BUDGET_SECONDS = 45.0

    /** A retry of [passSeconds] still fits when [elapsedSeconds] have already gone. */
    fun retryFits(elapsedSeconds: Double, passSeconds: Double, budget: Double = RETRY_BUDGET_SECONDS): Boolean =
        passSeconds > 0 && elapsedSeconds + passSeconds <= budget

    /** Refusal phrases, whole phrases only ("make out" alone is a description). */
    private val REFUSAL_MARKERS = listOf(
        "can't make out", "cannot make out", "can not make out",
        "couldn't make out", "could not make out",
        "can't see", "cannot see", "can't read", "cannot read",
        "can't tell", "cannot tell", "can't determine", "cannot determine",
        "unable to", "too dark to", "too blurry to", "too dark and blurry",
        "retake", "hold the camera still", "hold the phone still",
        "turn on a light", "turn on the flash", "add some light",
        "move closer", "take the picture again", "take it again",
        "try again", "not clear enough", "no details are visible",
    )

    /** Says it can't see or asks for a new shot somewhere in [s]. */
    fun looksLikeRefusal(s: String?): Boolean {
        val t = s?.lowercase()?.replace('’', '\'') ?: return true
        return REFUSAL_MARKERS.any { t.contains(it) }
    }

    /** Words that only talk about the photo itself, not what is in it. */
    private val PHOTO_TALK = Regex(
        "\\b(it'?s|it is|this is|the (image|photo|picture|shot|scene) is|hard to see|hard to tell|" +
            "blurry|blurred|out of focus|too dark|very dark|unclear|i think|i can make out|i can see)\\b"
    )

    /**
     * True when the answer, once its refusal clauses are set aside, still says what is there:
     * "It's too dark to see much, but there is a lamp on a table" describes; "I can't see
     * anything, please retake the photo" does not.
     */
    fun hasDescription(s: String?): Boolean {
        if (s.isNullOrBlank()) return false
        return clauses(s).any { c ->
            !looksLikeRefusal(c) && !isInstruction(c) && contentWords(c) >= 1
        }
    }

    /** A real refusal: refusal words and nothing described around them. */
    fun isRefusal(s: String?): Boolean = s.isNullOrBlank() || (looksLikeRefusal(s) && !hasDescription(s))

    private fun clauses(s: String): List<String> =
        s.split(Regex("[.!?;]+|,\\s*(but|though|although|yet)\\s+|\\s+but\\s+", RegexOption.IGNORE_CASE))
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    private fun contentWords(clause: String): Int {
        val stripped = PHOTO_TALK.replace(clause.lowercase().replace('’', '\''), " ")
        return stripped.split(Regex("[^\\p{L}\\p{N}']+")).count { it.length >= 3 && it !in FILLER }
    }

    private val FILLER = setOf(
        "the", "and", "that", "this", "there", "with", "some", "what", "can", "see", "make", "out",
        "just", "very", "much", "anything", "something", "seems", "appears", "looks", "like",
        "image", "photo", "picture", "shot", "camera", "light", "lighting", "detail", "details",
        "sorry", "clearly", "clear", "well", "here", "please", "enough", "thing", "things", "everything",
        "any", "lot", "not", "too", "dark", "dim", "blurry", "unclear", "visible", "seen", "tell",
        // An apology is not a description: "I'm sorry, but I can't see..." is a refusal (11/04 review).
        "i'm", "im", "i've", "i'd", "i'll", "you", "your", "unfortunately", "afraid", "apologize",
        "apologies", "however", "really", "quite", "but",
    )

    /**
     * Fragments that are a clause about the photo, not a thing in it ("it's just a blurry",
     * "the photo is dark", "too dim to see"). A thing that is dark is still a thing: "a dark
     * blue mug" and "a dim lamp" stay (11/04 review).
     */
    private fun isPhotoTalk(fragment: String): Boolean {
        val f = fragment.lowercase().replace('’', '\'').trim()
        if (PHOTO_TALK_FRAGMENT.containsMatchIn(f)) return true
        if (Regex("^(it|this|that|there|they|these|those|i|we|you)\\b").containsMatchIn(f)) return true
        if (PHOTO_STATE_ONLY.matches(f)) return true
        return Regex("\\b(image|photo|picture|unclear|nothing)\\b").containsMatchIn(f)
    }

    /** Talk about the photo inside a fragment: [PHOTO_TALK] without the bare "very dark"/"blurry". */
    private val PHOTO_TALK_FRAGMENT = Regex(
        "\\b(it'?s|it is|this is|the (image|photo|picture|shot|scene)|hard to see|hard to tell|" +
            "out of focus|i think|i can make out|i can see|" +
            "(too|so) (dark|dim|blurry|blurred|grainy|fuzzy)|(dark|dim|blurry|blurred) to (see|tell|make))\\b"
    )

    /** A fragment that is nothing but how the photo looks: "dark", "very dim", "dark and blurry". */
    private val PHOTO_STATE_ONLY = Regex(
        "^(?:(?:just|too|very|quite|really|so|a bit|a little|kind of|pretty|rather|and|or|a)\\s+)*" +
            "(?:dark|dim|blurry|blurred|grainy|fuzzy|murky|shadowy|unclear)" +
            "(?:\\s+(?:and|or)\\s+(?:(?:too|very|quite|a bit)\\s+)?(?:dark|dim|blurry|blurred|grainy|fuzzy|murky|shadowy|unclear))*" +
            "(?:\\s+(?:image|photo|picture|shot|scene|lighting|light))?$"
    )

    private val INSTRUCTION_VERBS = listOf(
        "hold", "move", "turn", "take", "try", "use", "ensure", "make sure",
        "point", "adjust", "increase", "retry", "please", "consider",
        "bring", "step", "add", "switch", "clean", "wipe", "check",
    )

    private fun isInstruction(fragment: String): Boolean {
        val f = fragment.lowercase().trim()
        return INSTRUCTION_VERBS.any { f.startsWith("$it ") || f == it }
    }

    /**
     * The noun list from the last-resort pass, as "a, b and c", or null when nothing in it is
     * a thing. Clauses about the photo, refusals, advice and long phrases are dropped.
     */
    fun thingsOnly(raw: String): String? {
        var text = raw.trim().trim('"', '\'')
        if (text.isEmpty()) return null
        for (opener in listOf(
            "in this picture, i can see", "in this photo, i can see",
            "i can see", "i see", "the things i can see are",
            "here is a list", "here are the things",
        )) {
            if (text.lowercase().startsWith(opener)) {
                text = text.substring(opener.length)
                break
            }
        }
        val things = text.split(',', '\n', ';', '.')
            .map { it.trim().trim('.', ':', '-', '*', ' ').removePrefix("and ").trim() }
            .filter {
                it.isNotEmpty() && it.length <= 40 && it.split(' ').size <= 4 &&
                    !looksLikeRefusal(it) && !isInstruction(it) && !isPhotoTalk(it)
            }
            .distinctBy { it.lowercase() }
        if (things.isEmpty()) return null
        val kept = things.take(4)
        return if (kept.size == 1) kept[0]
        else kept.dropLast(1).joinToString(", ") + " and " + kept.last()
    }

    /** The answer's own descriptive sentences, or the honest floor line when there are none. */
    fun strippingExcuses(sentence: String?): String {
        if (!sentence.isNullOrBlank()) {
            val described = sentence.split('.', '!', '?', ';')
                .map { it.trim() }
                .filter { it.isNotEmpty() && !looksLikeRefusal(it) }
            if (described.isNotEmpty()) {
                val rebuilt = described.joinToString(". ") + "."
                if (rebuilt.length >= 12) return rebuilt
            }
        }
        return HARD_TO_SEE
    }

    const val HARD_TO_SEE = "It's hard to see clearly, and I couldn't make out enough to say."

    /** Words a cut-off answer must not end on. */
    private val DANGLING = setOf(
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "with", "for", "from",
        "by", "is", "are", "was", "it's", "its", "just", "very", "some", "that", "which", "there",
        "this", "his", "her", "their", "your", "my", "as", "if", "so", "than", "into", "onto",
    )

    /**
     * Never stop in the middle of a sentence. Only an answer the model was cut off in (it used
     * every token it was allowed, [hitTokenLimit]) can end mid-sentence: that one is cut back to
     * its last full sentence, and with no full sentence at all a dangling little word is dropped
     * and the sentence is closed. An answer the model finished on its own is kept whole, even when
     * its last sentence has no period ("Amount due: $84.20 by Nov 12" is the answer, 11/04 review).
     */
    fun completeSentences(text: String, hitTokenLimit: Boolean): String {
        val t = text.trim()
        if (t.isEmpty() || !hitTokenLimit) return t
        val core = t.trimEnd('"', '\'', ')', '”', '’', '»')
        if (core.isNotEmpty() && core.last() in ".!?…") return t
        val lastEnd = Regex("[.!?…][\"'”’)»]*(?=\\s)").findAll(t).lastOrNull()
        if (lastEnd != null) return t.substring(0, lastEnd.range.last + 1).trim()
        val words = t.trimEnd(',', ';', ':', '-', '—', ' ').split(Regex("\\s+")).toMutableList()
        while (words.size > 1 && words.last().lowercase().trim(',', ';', ':') in DANGLING) words.removeAt(words.lastIndex)
        return words.joinToString(" ").trimEnd(',', ';', ':', '-', '—') + "."
    }

    /**
     * How much to brighten a dim shot before the FIRST pass, from its mean brightness (0-255),
     * or null when it is bright enough. Brightening up front costs nothing; a retry pass costs
     * the whole answer time again.
     */
    fun brightenFactor(meanLuma: Double): Float? {
        if (meanLuma <= 0.0 || meanLuma >= DIM_LUMA) return null
        return (TARGET_LUMA / meanLuma).coerceIn(1.2, 2.4).toFloat()
    }

    const val DIM_LUMA = 70.0
    private const val TARGET_LUMA = 110.0
}
