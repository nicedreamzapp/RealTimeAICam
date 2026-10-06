package com.mattmacosko.realtimeaicam.translation

import com.google.mlkit.nl.translate.TranslateLanguage

/**
 * The languages the Translator reads (2026-09-21, Enes Deniz on AppleVis asked for more than
 * Spanish). Spanish keeps Matt's own offline engine with no download. Every other language uses
 * Google's on-device translation pack, downloaded once on first use and offline after that.
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

    fun byCode(code: String?): ReaderLanguage = all.firstOrNull { it.code == code } ?: spanish
}
