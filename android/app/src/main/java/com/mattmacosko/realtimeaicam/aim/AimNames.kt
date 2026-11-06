package com.mattmacosko.realtimeaicam.aim

import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.translation.ObjectLabelTranslations
import java.util.concurrent.ConcurrentHashMap

/**
 * Object names inside Help Me Aim's own lines (2026-11-05, Spanish UI).
 *
 * The lines themselves come from the app's strings (values-es ships in the app), but a name
 * like "key" is content: the detector's English class name or the word the person asked for.
 * In an English app the name is said exactly as before ("a key"), and a Your-language line is
 * still translated whole by the announcer. In a Spanish app the line is already Spanish, so
 * only the name goes through Your language's on-device translator (never a download), once,
 * and is cached: "una llave". With no Spanish pack on the phone the English name stays, as it
 * did before this change.
 *
 * [translate] is set by the screen and must return null on the main thread (the translator
 * blocks); the screen warms the subject's name off the main thread before it is first said.
 */
object AimNames {
    /** (English phrase, language) -> the phrase in that language, or null when it can't. */
    @Volatile var translate: ((String, String) -> String?)? = null

    private val cache = ConcurrentHashMap<String, String>()
    private val missed = ConcurrentHashMap<String, Long>()
    private const val MISS_RETRY_MS = 30_000L

    /** "a key" in English; "una llave" in a Spanish app once translated. */
    fun withArticle(word: String): String = withArticle(word, article = true)

    /** For the "I can see a dog, glasses and a mirror" list: no article on glasses. */
    fun listed(word: String): String = withArticle(word, article = !AimElsewhere.noArticle.contains(word))

    /** "key" in English; "llave" in a Spanish app once translated. */
    fun bare(word: String): String {
        val lang = AppLang.code()
        if (lang == AppLang.ENGLISH || word.isBlank()) return word
        exact(word, lang)?.let { return it }
        return translated(source(word), lang, bare = true) ?: word
    }

    private fun withArticle(word: String, article: Boolean): String {
        val english = if (article) AimVocabulary.withArticle(word) else word
        val lang = AppLang.code()
        if (lang == AppLang.ENGLISH || word.isBlank()) return english
        // Hand-fixed names skip the translator (review rule: "taza"). Every Spanish one is a
        // feminine noun today, so "una".
        exact(word, lang)?.let { return if (article && lang == AppLang.SPANISH) "una $it" else it }
        val src = source(word)
        return translated(if (article) AimVocabulary.withArticle(src) else src, lang, bare = !article) ?: english
    }

    /** A bare word is ambiguous to a translator ("glasses"): Object Detection's context phrase. */
    private fun source(word: String): String =
        ObjectLabelTranslations.CONTEXT[word.replaceFirstChar { it.uppercase() }] ?: word

    private fun exact(word: String, lang: String): String? =
        ObjectLabelTranslations.exactName(word.replaceFirstChar { it.uppercase() }, lang)

    private fun translated(phrase: String, lang: String, bare: Boolean): String? {
        val key = "$lang|$bare|$phrase"
        cache[key]?.let { return it }
        // A miss (no Spanish pack, or asked on the main thread) is not asked again for a while:
        // the camera path builds these lines every frame.
        val now = System.nanoTime() / 1_000_000
        missed[key]?.let { if (now - it < MISS_RETRY_MS) return null else missed.remove(key) }
        val t = translate ?: return null
        // Never block the main thread on the translator, and never count that as a miss (warm()
        // on a worker right after must still ask).
        if (onMainThread()) return null
        val raw = t(phrase, lang)
        if (raw == null) { missed[key] = now; return null }
        val clean = if (bare) ObjectLabelTranslations.cleanOutput(raw, lang) else ObjectLabelTranslations.cleanOutput(raw)
        val out = clean.trim().trimEnd('.', '!', '?')
        if (out.isEmpty()) { missed[key] = now; return null }
        cache[key] = out
        return out
    }

    /** The main looper's thread (false in JVM unit tests, which have no looper). */
    @Volatile var onMainThread: () -> Boolean = {
        try { android.os.Looper.myLooper() == android.os.Looper.getMainLooper() } catch (_: Throwable) { false }
    }

    /** Off the main thread: translate [subject]'s name now, so the first line is not English. */
    fun warm(subject: AimSubject) {
        subject.spokenName
        when (subject) {
            is AimSubject.Obj -> bare(subject.match.spokenName)
            is AimSubject.Described -> bare(subject.word)
            else -> Unit
        }
    }

    /** Tests. */
    fun clear() { cache.clear(); missed.clear() }
}
