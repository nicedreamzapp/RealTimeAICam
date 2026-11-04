package com.mattmacosko.realtimeaicam.translation

/**
 * What's this? in Your language (2026-11-04). The vision model reads and writes English, so
 * its answer is translated into Your language before it is shown and said, and a follow-up
 * question asked in Your language is put into English before it goes to the model.
 * [translate] is (text, from, to) -> translation, or null when it can't (no pack, error):
 * then the English stands, exactly as before. Pure, unit tested; iOS does the same.
 */
object AnswerLanguage {
    /** The answer to show and say, and the language it ended up in. */
    fun forPerson(english: String, lang: String, translate: (String, String, String) -> String?): Pair<String, String> {
        if (lang == YourLanguageRules.ENGLISH || english.isBlank()) return english to YourLanguageRules.ENGLISH
        val out = translate(english, YourLanguageRules.ENGLISH, lang)
        return if (out.isNullOrBlank()) english to YourLanguageRules.ENGLISH else out to lang
    }

    /** The question for the model, in English. */
    fun questionForModel(question: String, lang: String, translate: (String, String, String) -> String?): String {
        if (lang == YourLanguageRules.ENGLISH || question.isBlank()) return question
        return translate(question, lang, YourLanguageRules.ENGLISH)?.takeIf { it.isNotBlank() } ?: question
    }
}
