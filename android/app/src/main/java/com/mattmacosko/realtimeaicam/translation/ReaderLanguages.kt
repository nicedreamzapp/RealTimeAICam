package com.mattmacosko.realtimeaicam.translation

import com.google.mlkit.nl.translate.TranslateLanguage

/**
 * The languages the Translator reads (2026-09-21, Enes Deniz on AppleVis asked for more than
 * Spanish). Every language, Spanish included (Matt's call 2026-10-23), uses Google's on-device
 * translation pack, downloaded once on first use and offline after that. Until Spanish's pack
 * is on the phone, Spanish still translates with Matt's built-in dictionary engine.
 * Only Latin-script languages: the bundled ML Kit text reader cannot see Chinese, Japanese,
 * Korean or Devanagari, and adding those readers would grow the app.
 */
data class ReaderLanguage(val code: String, val name: String, val tag: String)

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
    )

    val spanish = all[0]

    /** Said (and shown) the first time a language downloads. Same words on iOS. */
    fun downloadLine(name: String): String = "Downloading $name, one time only. After that it works offline."

    fun byCode(code: String?): ReaderLanguage = all.firstOrNull { it.code == code } ?: spanish
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

    /** The pill's position for the current screen. */
    fun indexOf(translating: Boolean, language: ReaderLanguage): Int =
        if (!translating) 0 else ReaderLanguages.all.indexOf(language).coerceAtLeast(0) + 1

    /** A tap steps to the next choice and wraps back to English. */
    fun next(index: Int): Int = (index + 1) % count

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
