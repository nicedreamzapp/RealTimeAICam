package com.mattmacosko.realtimeaicam.translation

import java.io.InputStream
import java.text.Normalizer

/**
 * Whole-sentence and whole-clause Spanish idioms, matched BEFORE Google's translator so
 * sayings it renders word for word come out as the English saying:
 * "No hay mal que por bien no venga" -> "Every cloud has a silver lining".
 * Only a complete sentence, or a complete clause, is ever replaced (clauses split at
 * commas and semicolons); single words are never patched. Same rules as iOS
 * SpanishIdiomPrepass.swift; the list is assets/es_idioms.json (tools/make-es-idioms.py),
 * byte-identical to the iPhone's copy. Matt's call 2026-10-23.
 */
object SpanishIdiomPrepass {
    sealed class Piece {
        /** Already English (an idiom). */
        data class Fixed(val text: String) : Piece()
        /** Spanish for the translator. */
        data class Translate(val text: String) : Piece()
    }

    @Volatile private var idioms: Map<String, String> = emptyMap()

    val isLoaded: Boolean get() = idioms.isNotEmpty()
    val size: Int get() = idioms.size

    /** Load es_idioms.json once (about 50 KB). */
    @Synchronized
    fun load(open: () -> InputStream) {
        if (idioms.isNotEmpty()) return
        idioms = open().use { parseFlatJson(it.readBytes().toString(Charsets.UTF_8)) }
    }

    /** Tests: use this map instead of the asset. */
    fun install(map: Map<String, String>) { idioms = map }

    /** Lowercase, accents folded, punctuation to spaces, spaces collapsed. */
    fun normalize(s: String): String {
        val folded = Normalizer.normalize(s.lowercase(), Normalizer.Form.NFD)
            .filter { Character.getType(it) != Character.NON_SPACING_MARK.toInt() }
        val spaced = folded.map { if (it.isLetter() || isNumber(it) || it == '_') it else ' ' }
            .joinToString("")
        return spaced.split(' ').filter { it.isNotEmpty() }.joinToString(" ")
    }

    private fun isNumber(c: Char): Boolean = when (Character.getType(c)) {
        Character.DECIMAL_DIGIT_NUMBER.toInt(),
        Character.LETTER_NUMBER.toInt(),
        Character.OTHER_NUMBER.toInt() -> true
        else -> false
    }

    /** Sentences, each with its own trailing punctuation and spacing kept. */
    fun sentences(text: String): List<String> {
        val out = ArrayList<String>()
        val current = StringBuilder()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            current.append(c)
            if (".!?…\n".indexOf(c) >= 0) {
                // keep closing punctuation and the spaces that follow with this sentence
                while (i + 1 < text.length && ".!?…\"”»)".indexOf(text[i + 1]) >= 0) { i++; current.append(text[i]) }
                while (i + 1 < text.length && text[i + 1].isWhitespace()) { i++; current.append(text[i]) }
                out.add(current.toString()); current.setLength(0)
            }
            i++
        }
        if (current.isNotEmpty()) out.add(current.toString())
        return out
    }

    private fun english(spanish: String): String? {
        val key = normalize(spanish)
        if (key.split(' ').filter { it.isNotEmpty() }.size < 3) return null
        return idioms[key]
    }

    /** Re-dress an idiom's English in the source's capital and punctuation. */
    private fun dress(english: String, source: String): String {
        var e = english
        val f = source.firstOrNull { it.isLetter() }
        if (f != null && f.isUpperCase() && e.isNotEmpty()) {
            e = e.substring(0, 1).uppercase() + e.substring(1)
        }
        val trimmed = source.trim()
        val tail = trimmed.reversed().takeWhile { !it.isLetter() && !isNumber(it) && "¿¡".indexOf(it) < 0 }
        val lead = source.takeWhile { it.isWhitespace() }
        val trail = source.reversed().takeWhile { it.isWhitespace() }.reversed()
        val punct = tail.reversed().replace("¿", "").replace("¡", "")
        return lead + e + punct + trail
    }

    /**
     * Split text into idiom pieces and pieces for the translator. Neighbouring translator
     * pieces are merged so the translator keeps its context.
     */
    fun plan(text: String): List<Piece> {
        val pieces = ArrayList<Piece>()
        fun add(p: Piece) {
            val prev = pieces.lastOrNull()
            if (p is Piece.Translate && prev is Piece.Translate) {
                pieces[pieces.size - 1] = Piece.Translate(prev.text + p.text)
            } else {
                pieces.add(p)
            }
        }
        for (sentence in sentences(text)) {
            val whole = english(sentence)
            if (whole != null) { add(Piece.Fixed(dress(whole, sentence))); continue }
            // Clauses, each keeping its own separator.
            val clauses = ArrayList<String>()
            val cur = StringBuilder()
            for (c in sentence) {
                cur.append(c)
                if (c == ',' || c == ';') { clauses.add(cur.toString()); cur.setLength(0) }
            }
            if (cur.isNotEmpty()) clauses.add(cur.toString())
            if (clauses.size > 1 && clauses.any { english(it) != null }) {
                for (clause in clauses) {
                    val e = english(clause)
                    if (e != null) add(Piece.Fixed(dress(e, clause))) else add(Piece.Translate(clause))
                }
            } else {
                add(Piece.Translate(sentence))
            }
        }
        return pieces
    }

    /** Run the plan: idiom pieces as they are, the rest through [translate]. */
    fun translate(text: String, translate: (String) -> String): String {
        val out = StringBuilder()
        for (piece in plan(text)) {
            when (piece) {
                is Piece.Fixed -> out.append(piece.text)
                is Piece.Translate -> {
                    val s = piece.text
                    val core = s.trim()
                    if (core.isEmpty() || core.none { it.isLetter() }) { out.append(s); continue }
                    val lead = s.takeWhile { it.isWhitespace() }
                    val trail = s.reversed().takeWhile { it.isWhitespace() }.reversed()
                    if (out.isNotEmpty() && lead.isEmpty() && !out.last().isWhitespace()) out.append(' ')
                    out.append(lead).append(translate(core)).append(trail)
                }
            }
        }
        return out.toString().trim()
    }

    /** es_idioms.json is one flat object of strings; read it without org.json so JVM tests can too. */
    internal fun parseFlatJson(json: String): Map<String, String> {
        val map = HashMap<String, String>(2048)
        var i = 0
        fun skipWs() { while (i < json.length && json[i].isWhitespace()) i++ }
        fun readString(): String {
            require(json[i] == '"') { "expected string at $i" }
            i++
            val sb = StringBuilder()
            while (true) {
                val c = json[i++]
                when (c) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        when (val e = json[i++]) {
                            'n' -> sb.append('\n'); 't' -> sb.append('\t'); 'r' -> sb.append('\r')
                            'b' -> sb.append('\b'); 'f' -> sb.append('\u000C')
                            'u' -> { sb.append(json.substring(i, i + 4).toInt(16).toChar()); i += 4 }
                            else -> sb.append(e)
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }
        skipWs(); require(json[i] == '{'); i++
        while (true) {
            skipWs()
            if (json[i] == '}') break
            val k = readString(); skipWs(); require(json[i] == ':'); i++; skipWs()
            map[k] = readString(); skipWs()
            if (json[i] == ',') i++
        }
        return map
    }
}
