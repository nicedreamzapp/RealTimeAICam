package com.mattmacosko.realtimeaicam.translation

import com.google.mlkit.nl.translate.TranslateLanguage
import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.R

/**
 * The languages the Translator reads (2026-09-21, Enes Deniz on AppleVis asked for more than
 * Spanish). Every language, Spanish included (Matt's call 2026-10-23), uses Google's on-device
 * translation pack, downloaded once on first use and offline after that. Until Spanish's pack
 * is on the phone, Spanish still translates with Matt's built-in dictionary engine.
 * The first ten are Latin script and use the reader built into the app. The other seven (iOS
 * parity 2026-11-04, 17 in all) need a reader the app does not carry, so the download adds
 * nothing for anyone who never picks them (Matt's rule): Chinese, Japanese and Korean use
 * Google's readers delivered by Play services, Russian, Ukrainian, Thai and Arabic use
 * Tesseract from the on-demand "readers" module plus one small file from our own server.
 * Nothing downloads until the person taps the card to get that language's reader.
 */
data class ReaderLanguage(
    val code: String,
    val name: String,
    val tag: String,
    val reader: ScriptReader = ScriptReader.LATIN,
) {
    /** True when reading this language needs a one-time download first. */
    val needsReaderDownload: Boolean get() = reader != ScriptReader.LATIN

    /** [name] in the app's language, as a label ("Francés" in Spanish). [name] stays English for logic and logs. */
    val displayName: String get() = LanguageNames.name(code)

    /** [displayName] inside a sentence: Spanish writes language names in lowercase ("en francés"). */
    val nameInSentence: String get() = LanguageNames.inSentence(code)
}

/**
 * Language names in the app's language (Spanish UI, 2026-11-05): what the Read pill, its
 * TalkBack label and the reader lines say. Shipped in the app's strings, so nothing downloads.
 */
object LanguageNames {
    fun name(code: String): String = AppLang.str(res(code))

    fun inSentence(code: String): String =
        if (AppLang.isSpanish) name(code).lowercase(AppLang.locale()) else name(code)

    private fun res(code: String): Int = when (code) {
        "es" -> R.string.f_lang_es
        "fr" -> R.string.f_lang_fr
        "de" -> R.string.f_lang_de
        "it" -> R.string.f_lang_it
        "pt" -> R.string.f_lang_pt
        "nl" -> R.string.f_lang_nl
        "pl" -> R.string.f_lang_pl
        "tr" -> R.string.f_lang_tr
        "id" -> R.string.f_lang_id
        "vi" -> R.string.f_lang_vi
        "ru" -> R.string.f_lang_ru
        "uk" -> R.string.f_lang_uk
        "zh" -> R.string.f_lang_zh
        "ja" -> R.string.f_lang_ja
        "ko" -> R.string.f_lang_ko
        "th" -> R.string.f_lang_th
        "ar" -> R.string.f_lang_ar
        else -> R.string.f_lang_en
    }
}

/** Which text reader sees a language's writing. */
enum class ScriptReader(val tessCode: String? = null) {
    /** Built into the app (ML Kit Latin). */
    LATIN,
    /** Google's readers, delivered by Play services when picked, not inside the app. */
    CHINESE, JAPANESE, KOREAN,
    /** Tesseract in the on-demand readers module; tessCode names its traineddata file. */
    TESS_RUSSIAN("rus"), TESS_UKRAINIAN("ukr"), TESS_THAI("tha"), TESS_ARABIC("ara");

    val isTesseract: Boolean get() = tessCode != null
}

object ReaderLanguages {
    val all = listOf(
        ReaderLanguage("es", "Spanish", "Span"),
        ReaderLanguage(TranslateLanguage.FRENCH, "French", "French"),
        ReaderLanguage(TranslateLanguage.GERMAN, "German", "German"),
        ReaderLanguage(TranslateLanguage.ITALIAN, "Italian", "Italian"),
        ReaderLanguage(TranslateLanguage.PORTUGUESE, "Portuguese", "Port"),
        ReaderLanguage(TranslateLanguage.DUTCH, "Dutch", "Dutch"),
        ReaderLanguage(TranslateLanguage.POLISH, "Polish", "Polish"),
        ReaderLanguage(TranslateLanguage.TURKISH, "Turkish", "Turkish"),
        ReaderLanguage(TranslateLanguage.INDONESIAN, "Indonesian", "Indo"),
        ReaderLanguage(TranslateLanguage.VIETNAMESE, "Vietnamese", "Viet"),
        // Same order as iOS appleCandidates.
        ReaderLanguage(TranslateLanguage.RUSSIAN, "Russian", "Rus", ScriptReader.TESS_RUSSIAN),
        ReaderLanguage(TranslateLanguage.UKRAINIAN, "Ukrainian", "Ukr", ScriptReader.TESS_UKRAINIAN),
        ReaderLanguage(TranslateLanguage.CHINESE, "Chinese", "Chin", ScriptReader.CHINESE),
        ReaderLanguage(TranslateLanguage.JAPANESE, "Japanese", "Jpn", ScriptReader.JAPANESE),
        ReaderLanguage(TranslateLanguage.KOREAN, "Korean", "Kor", ScriptReader.KOREAN),
        ReaderLanguage(TranslateLanguage.THAI, "Thai", "Thai", ScriptReader.TESS_THAI),
        ReaderLanguage(TranslateLanguage.ARABIC, "Arabic", "Arab", ScriptReader.TESS_ARABIC),
    )

    val spanish = all[0]

    /**
     * Said (and shown) the first time a language downloads. Same words on iOS. [name] is the
     * language's name in the app's language, as it sits inside a sentence ([ReaderLanguage.nameInSentence]).
     */
    fun downloadLine(name: String): String = AppLang.str(R.string.f_reader_downloading, name)

    fun byCode(code: String?): ReaderLanguage = all.firstOrNull { it.code == code } ?: spanish

    /**
     * Shown and said when a picked language's reader is not on the phone yet. Nothing downloads until the tap.
     * [name] starts the sentence ([ReaderLanguage.displayName]); same for [offlineLine] and [readyLine].
     */
    fun offerLine(name: String): String = AppLang.str(R.string.f_reader_offer, name)

    /** Said when the picked language's reader needs a connection it does not have. */
    fun offlineLine(name: String): String = AppLang.str(R.string.f_reader_offline, name)

    /** Said once the reader (and its translation pack) is on the phone. */
    fun readyLine(name: String): String = AppLang.str(R.string.f_reader_ready, name)

    /**
     * Sign and page lines to translate one at a time. Scripts with capital letters keep the
     * shared rule (a lowercase start continues the line before). Chinese, Japanese, Korean,
     * Thai and Arabic have no capitals, so a line that does not end a sentence is joined to the
     * next instead (no space for Chinese and Japanese, which use none between words).
     */
    fun translationUnits(lang: ReaderLanguage, text: String): List<String> {
        if (lang.reader == ScriptReader.LATIN || lang.reader == ScriptReader.TESS_RUSSIAN ||
            lang.reader == ScriptReader.TESS_UKRAINIAN
        ) return SpanishTranslationEngine.translationUnits(text)
        val glue = if (lang.reader == ScriptReader.CHINESE || lang.reader == ScriptReader.JAPANESE) "" else " "
        val units = ArrayList<String>()
        var joinNext = false
        for (raw in text.split('\n', '\r')) {
            val t = raw.trim()
            if (t.isEmpty()) { joinNext = false; continue }
            if (joinNext && units.isNotEmpty()) units[units.size - 1] = units.last() + glue + t else units.add(t)
            joinNext = t.last() !in SENTENCE_ENDS
        }
        return units
    }

    private const val SENTENCE_ENDS = ".!?:;。！？：；…؟؛"
}

/**
 * Read + Translate are one Read button (iOS parity, 2026-11-03). The language pill on the
 * Read screen picks English (read as it is) or one of [ReaderLanguages.all] (translated into
 * English). Index 0 is English; index i is ReaderLanguages.all[i - 1]. The choice is
 * remembered, so Read opens the way it was left.
 */
object ReaderChoice {
    const val PREF_FILE = "rtcam"
    const val KEY = "readerLanguageMode"
    const val ENGLISH = "english"
    const val TRANSLATE = "translate"

    val count: Int get() = ReaderLanguages.all.size + 1

    /** Pill text for a choice. */
    fun label(index: Int): String =
        if (index <= 0) "English" else "${ReaderLanguages.all[index - 1].tag} → Eng"

    /** What a screen reader hears, and what is said when the choice changes. */
    fun spoken(index: Int): String =
        if (index <= 0) "English" else "${ReaderLanguages.all[index - 1].name}, translated to English"

    /**
     * The pill as shown, in the app's language. An English app keeps exactly
     * [YourLanguageRules.pillLabel]; a Spanish one names the languages in Spanish
     * ("Francés → Ing", "Francés → Español"), the same as iOS.
     */
    fun pillLabel(page: ReaderLanguage?, target: String): String {
        if (!AppLang.isSpanish) return YourLanguageRules.pillLabel(page, target)
        val en = YourLanguageRules.ENGLISH
        if (target == en) return if (page == null) LanguageNames.name(en)
            else AppLang.str(R.string.f_pill_to_eng, page.displayName)
        val from = page?.code ?: en
        return if (from == target) LanguageNames.name(target)
            else "${LanguageNames.name(from)} → ${LanguageNames.name(target)}"
    }

    /** What TalkBack hears for the pill, and what is said when it changes, in the app's language. */
    fun pillSpoken(page: ReaderLanguage?, target: String): String {
        if (!AppLang.isSpanish) return YourLanguageRules.pillSpoken(page, target)
        val from = page?.code ?: YourLanguageRules.ENGLISH
        if (from == target) return LanguageNames.name(target)
        return AppLang.str(R.string.f_pill_translated, LanguageNames.name(from), LanguageNames.inSentence(target))
    }

    /** The pill's position for the current screen. */
    fun indexOf(translating: Boolean, language: ReaderLanguage): Int =
        if (!translating) 0 else ReaderLanguages.all.indexOf(language).coerceAtLeast(0) + 1

    /** A tap steps to the next choice and wraps back to English. */
    fun next(index: Int): Int = (index + 1) % count
    /** One back, wrapping from English to the last language (TalkBack's "Previous language"). */
    fun previous(index: Int): Int = (index - 1 + count) % count

    fun opensTranslating(context: android.content.Context): Boolean =
        context.getSharedPreferences(PREF_FILE, android.content.Context.MODE_PRIVATE)
            .getString(KEY, ENGLISH) == TRANSLATE

    fun remember(context: android.content.Context, translating: Boolean) {
        context.getSharedPreferences(PREF_FILE, android.content.Context.MODE_PRIVATE).edit()
            .putString(KEY, if (translating) TRANSLATE else ENGLISH).apply()
    }

    /** Said by the Read screen that opens after the pill switched modes. */
    @Volatile var pendingAnnouncement: String? = null
}
