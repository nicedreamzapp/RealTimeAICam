package com.mattmacosko.realtimeaicam.translation

import android.util.JsonReader
import android.util.JsonToken
import java.io.BufferedInputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.text.Normalizer
import java.util.regex.Matcher
import java.util.regex.Pattern
import java.util.zip.GZIPInputStream

/**
 * Kotlin port of the iOS `FixedSpanishEngine` (SpanishTranslationEngine.swift, project 601).
 *
 * Offline Spanish -> English translation driven by a gzipped JSON data file
 * (`es_final_with_rules.json.gz` in assets) containing:
 *   - "dictionary": surface form -> { translation, pos } (~268k entries, keys lowercased at load)
 *   - "rules": buckets of phrase maps (phrases / commonPhrases / idioms / menuPhrases / ...)
 *     and, optionally, "reflexive_passives" + "regex_rules" (absent in the current data file,
 *     but parsed for parity with the Swift engine).
 *
 * Pipeline (identical order to Swift):
 *   cache lookup -> domain detection -> sentence split -> batching (2200 chars)
 *   -> tokenize -> phrase match (longest-first, diacritic-folded)
 *   -> noun/adjective reorder -> word lookup w/ clitic handling
 *   -> rule packs: reflexive (non-narrative), builtin price/units, builtin menu lexicon,
 *      builtin al+infinitivo, builtin prepositions, JSON general, JSON grammar,
 *      builtin narrative grammar, (narrative only: builtin dialogue, JSON dialogue),
 *      JSON cleanup -> finalize (punctuation spacing + sentence capitalization).
 *
 * Usage (load is slow — a few seconds for the 26 MB decompressed JSON — call off the main thread):
 *   val engine = SpanishTranslationEngine()
 *   engine.load(context.assets.open("es_final_with_rules.json.gz"))   // background thread!
 *   val english = engine.translate("El menú del día")                 // any thread
 *
 * All stores are written once during load and only read afterwards; translate() is
 * thread-safe (the result cache is the only mutable state and is lock-guarded).
 */
class SpanishTranslationEngine {

    // ------------------------------------------------------------------
    // Public state
    // ------------------------------------------------------------------

    @Volatile
    var isLoaded: Boolean = false
        private set

    /** Number of single-surface dictionary entries loaded (0 until load() succeeds). */
    val entryCount: Int
        get() = dict.size

    fun isReady(): Boolean = isLoaded

    // ------------------------------------------------------------------
    // Core stores (written once by load(), then read-only)
    // ------------------------------------------------------------------

    private var dict: Map<String, String> = emptyMap()      // surface (lowercased) -> translation
    private var posMap: Map<String, String> = emptyMap()    // surface -> NOUN/ADJ/ADV/VERB
    private var phraseMatcher: PhraseMatcher? = null
    private var reflexiveRules: List<Rule> = emptyList()

    // Compiled regex packs from JSON (empty with the current data file — kept for parity)
    private var compiledGeneral: List<Rule> = emptyList()
    private var compiledDialogueFromJSON: List<Rule> = emptyList()
    private var compiledGrammar: List<Rule> = emptyList()
    private var compiledCleanup: List<Rule> = emptyList()

    // Built-in deterministic rule packs
    private var builtinPriceAndUnits: List<Rule> = emptyList()
    private var builtinAlInfinitivo: List<Rule> = emptyList()
    private var builtinPrepositions: List<Rule> = emptyList()
    private var builtinMenuLexicon: List<Rule> = emptyList()
    private var builtinNarrativeGrammar: List<Rule> = emptyList()
    private var builtinDialogue: List<Rule> = emptyList()

    // Cache is the only state mutated after load; guard it.
    private val stateLock = Any()
    private val cache = HashMap<String, String>()
    private val cacheLimit = 500

    // ------------------------------------------------------------------
    // Public API
    // ------------------------------------------------------------------

    /**
     * Loads the translation data synchronously from [input] (e.g.
     * `context.assets.open("es_final_with_rules.json.gz")`). Call on a background thread.
     *
     * @param gzipped true (default) when the stream is the .json.gz asset; pass false for raw JSON.
     * @return true on success.
     */
    fun load(input: InputStream, gzipped: Boolean = true): Boolean {
        return try {
            val raw = if (gzipped) GZIPInputStream(BufferedInputStream(input)) else BufferedInputStream(input)
            JsonReader(InputStreamReader(raw, Charsets.UTF_8)).use { reader -> loadFrom(reader) }
            synchronized(stateLock) {
                cache.clear()
                isLoaded = true
            }
            true
        } catch (t: Throwable) {
            false
        }
    }

    /** Translates Spanish [text] to English. Returns [text] unchanged if not loaded or empty. */
    fun translate(text: String): String {
        if (!isLoaded) return text
        if (text.isEmpty()) return text
        return interpretSpanishWithContext(text)
    }

    companion object {
        /** Convenience: construct + load in one call (blocking — background thread!). */
        fun load(input: InputStream, gzipped: Boolean = true): SpanishTranslationEngine {
            val e = SpanishTranslationEngine()
            e.load(input, gzipped)
            return e
        }

        // Spanish object pronouns come before the verb; English puts them after
        // ("me ofreció" -> "offered me"). Empty value = drop entirely (reflexive "se").
        private val CLITIC_OBJECTS = mapOf(
            "me" to "me", "te" to "you", "le" to "him", "les" to "them",
            "nos" to "us", "os" to "you", "se" to "",
        )

        // Verb translations that already carry their subject ("I woke up") absorb the clitic.
        private val SUBJECT_STARTS = listOf("i ", "he ", "she ", "we ", "they ", "you ", "it ")

        private val WS = Pattern.compile("\\s+")

        /** Diacritic-insensitive fold, mirroring Swift's .diacriticInsensitive folding. */
        internal fun fold(s: String): String {
            if (s.all { it.code < 0x80 }) return s // fast path: pure ASCII
            val nfd = Normalizer.normalize(s, Normalizer.Form.NFD)
            val sb = StringBuilder(nfd.length)
            for (ch in nfd) {
                val type = Character.getType(ch)
                if (type != Character.NON_SPACING_MARK.toInt()) sb.append(ch)
            }
            return sb.toString()
        }

        internal fun collapseWhitespace(s: String): String =
            WS.matcher(s).replaceAll(" ").trim()
    }

    private data class Rule(val pattern: Pattern, val replacement: String)

    private enum class TextDomain { RESTAURANT, SIGNAGE, NARRATIVE, GENERAL }

    // ------------------------------------------------------------------
    // Phrase matcher (Aho-Corasick-lite, mirrors Swift PhraseMatcher)
    // ------------------------------------------------------------------

    private class PhraseMatcher(phrases: Map<String, String>) {
        private val phraseMap: Map<String, String>
        private val lengths: List<Int>

        init {
            val norm = HashMap<String, String>(phrases.size)
            for ((k, v) in phrases) {
                val nk = normalize(k)
                if (nk.isNotEmpty()) norm[nk] = v
            }
            phraseMap = norm
            lengths = norm.keys.map { it.split(' ').size }.distinct().sortedDescending()
        }

        companion object {
            private fun normalize(s: String): String =
                collapseWhitespace(fold(s.lowercase()))
        }

        /** tokens must already be lowercased by the caller (as in Swift). */
        fun match(tokens: List<String>): List<Pair<String, String?>> {
            // Keys are stored accent-folded, so the lookup must fold too.
            val folded = tokens.map { fold(it) }
            var i = 0
            val out = ArrayList<Pair<String, String?>>(tokens.size)
            while (i < tokens.size) {
                var matched = false
                for (len in lengths) {
                    if (i + len > tokens.size) continue
                    val foldedSpan = folded.subList(i, i + len).joinToString(" ")
                    val eng = phraseMap[foldedSpan]
                    if (eng != null) {
                        out.add(tokens.subList(i, i + len).joinToString(" ") to eng)
                        i += len
                        matched = true
                        break
                    }
                }
                if (!matched) {
                    out.add(tokens[i] to null)
                    i += 1
                }
            }
            return out
        }
    }

    // ------------------------------------------------------------------
    // Core translation logic
    // ------------------------------------------------------------------

    private fun interpretSpanishWithContext(text: String): String {
        val cacheKey = normalizeKey(text)
        synchronized(stateLock) { cache[cacheKey] }?.let { return it }

        val domain = detectDomain(text)
        val sentences = splitIntoSentences(text)
        val batches = batchSentences(sentences, targetChars = 2200)

        val outPieces = ArrayList<String>(batches.size)
        for (batch in batches) outPieces.add(translateBatch(batch, domain))
        val result = collapseWhitespace(outPieces.joinToString(" "))

        // OCR feeds a near-infinite stream of unique strings, so cap the cache.
        synchronized(stateLock) {
            if (cache.size >= cacheLimit) cache.clear()
            cache[cacheKey] = result
        }
        return result
    }

    private fun lookup(surface: String): String? =
        dict[surface] ?: dict[fold(surface)]

    private fun posOf(token: String): String? =
        posMap[token] ?: posMap[fold(token)]

    // "el gato se abalanzó" must not become "the cat He pounced": when the sentence
    // already has a subject (a noun right before the verb), strip the subject
    // pronoun some dictionary verb translations carry embedded.
    private fun stripEmbeddedSubject(verbTr: String): String {
        val lower = verbTr.lowercase() + " "
        for (s in SUBJECT_STARTS) {
            if (lower.startsWith(s)) return verbTr.substring(s.length)
        }
        return verbTr
    }

    // Spanish puts adjectives after nouns ("paraguas azul"); English reverses
    // ("blue umbrella"). Applies only to spans the phrase matcher didn't claim.
    private fun reorderNounAdjective(items: List<Pair<String, String?>>): List<Pair<String, String?>> {
        val out = ArrayList(items)
        var i = 0
        while (i < out.size - 1) {
            if (!(out[i].second == null && out[i + 1].second == null && posOf(out[i].first) == "NOUN")) {
                i += 1
                continue
            }
            // A following "de" marks a participial phrase ("manos cubiertas de
            // harina" = hands covered WITH flour) — reordering those reads worse.
            fun adjFollowedByDe(adjIdx: Int): Boolean =
                adjIdx + 1 < out.size && out[adjIdx + 1].first == "de"

            if (i + 2 < out.size && out[i + 2].second == null &&
                posOf(out[i + 1].first) == "ADV" && posOf(out[i + 2].first) == "ADJ" &&
                !adjFollowedByDe(i + 2)
            ) {
                // "pan recién horneado" -> "recién horneado pan" -> "freshly baked bread"
                val noun = out[i]
                out[i] = out[i + 1]; out[i + 1] = out[i + 2]; out[i + 2] = noun
                i += 3
            } else if (posOf(out[i + 1].first) == "ADJ" && !adjFollowedByDe(i + 1)) {
                val tmp = out[i]; out[i] = out[i + 1]; out[i + 1] = tmp
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    private fun englishPieces(items: List<Pair<String, String?>>): List<String> {
        val pieces = ArrayList<String>(items.size)
        var prevWasNoun = false
        var i = 0
        while (i < items.size) {
            val (surface, ph) = items[i]
            if (ph != null) {
                pieces.add(ph)
                prevWasNoun = false
                i += 1
                continue
            }

            val pos = posOf(surface)

            // Clitic pronoun directly before a verb
            val obj = CLITIC_OBJECTS[surface]
            if (obj != null && i + 1 < items.size && items[i + 1].second == null &&
                posOf(items[i + 1].first) == "VERB"
            ) {
                val verbTr = lookup(items[i + 1].first)
                if (verbTr != null) {
                    val lower = verbTr.lowercase() + " "
                    val subjectEmbedded = SUBJECT_STARTS.any { lower.startsWith(it) }
                    pieces.add(if (prevWasNoun) stripEmbeddedSubject(verbTr) else verbTr)
                    if (obj.isNotEmpty() && !subjectEmbedded) pieces.add(obj)
                    prevWasNoun = false
                    i += 2
                    continue
                }
            }

            val eng = lookup(surface)
            if (eng != null) {
                pieces.add(if (pos == "VERB" && prevWasNoun) stripEmbeddedSubject(eng) else eng)
            } else {
                pieces.add(surface) // unknown word falls through untranslated
            }
            prevWasNoun = (pos == "NOUN")
            i += 1
        }
        return pieces
    }

    private fun translateBatch(text: String, domain: TextDomain): String {
        val tokens = tokenize(collapseWhitespace(text))
        val lowered = tokens.map { it.lowercase() }
        val phraseApplied = phraseMatcher?.match(lowered) ?: lowered.map { it to null }

        var out = englishPieces(reorderNounAdjective(phraseApplied)).joinToString(" ")

        // Fast reflexive pack for menus/signage/general
        if (domain == TextDomain.RESTAURANT || domain == TextDomain.SIGNAGE || domain == TextDomain.GENERAL) {
            out = applyRulePack(reflexiveRules, out)
        }

        // Built-ins first (surgical, deterministic)
        out = applyRulePack(builtinPriceAndUnits, out)
        out = applyRulePack(builtinMenuLexicon, out)
        out = applyRulePack(builtinAlInfinitivo, out)
        out = applyRulePack(builtinPrepositions, out)

        // JSON packs
        out = applyRulePack(compiledGeneral, out)
        out = applyRulePack(compiledGrammar, out)

        // Built-in narrative grammar targets
        out = applyRulePack(builtinNarrativeGrammar, out)

        // Dialogue: built-in first, then any JSON dialogue
        if (domain == TextDomain.NARRATIVE) {
            out = applyRulePack(builtinDialogue, out)
            out = applyRulePack(compiledDialogueFromJSON, out)
        }

        // Cleanup (from JSON)
        out = applyRulePack(compiledCleanup, out)

        return finalize(out)
    }

    private fun applyRulePack(pack: List<Rule>, text: String): String {
        if (pack.isEmpty()) return text
        var s = text
        for (rule in pack) {
            s = rule.pattern.matcher(s).replaceAll(rule.replacement)
        }
        return s
    }

    // ------------------------------------------------------------------
    // Text processing utilities
    // ------------------------------------------------------------------

    private fun detectDomain(text: String): TextDomain {
        val t = text.lowercase()
        val menuHits = listOf(
            "menú", "menu", "plato", "platos", "postre", "entrante", "bebida", "bebidas",
            "cuenta", "€", "euros", "kilo", "docena", "kg", "precio", "oferta",
        ).count { t.contains(it) }
        val signHits = listOf(
            "se vende", "se alquila", "prohibido", "entrada", "salida", "cerrado",
            "abierto", "peligro", "precaución", "no fumar", "no pasar",
        ).count { t.contains(it) }
        val narrativeHits = listOf(
            "ayer", "mañana", "me desperté", "mientras", "de pronto", "cuando", "entonces",
            "luego", "sonriendo", "caminé", "pensé", "observé", "—", "\"",
        ).count { t.contains(it) }
        val m = maxOf(menuHits, signHits, narrativeHits)
        if (m == 0) return TextDomain.GENERAL
        if (m == menuHits) return TextDomain.RESTAURANT
        if (m == signHits) return TextDomain.SIGNAGE
        return TextDomain.NARRATIVE
    }

    private val sentenceSplitPattern =
        Pattern.compile("(?<=[.!?])\\s+(?=[A-ZÀ-Ú“”])")

    private fun splitIntoSentences(text: String): List<String> {
        if (text.isEmpty()) return emptyList()
        var s = text
        val abbrs = listOf("Sr", "Sra", "Dr", "Dra", "etc", "vs", "pág", "pp")
        for (abbr in abbrs) {
            // Case-insensitive literal replace, normalizing to the canonical abbr case
            // (matches Swift's replacingOccurrences(options: .caseInsensitive)).
            s = Pattern.compile(Pattern.quote("$abbr."), Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE)
                .matcher(s).replaceAll(Matcher.quoteReplacement("$abbr<<DOT>>"))
        }
        val sentences = ArrayList<String>()
        val m = sentenceSplitPattern.matcher(s)
        var last = 0
        while (m.find()) {
            sentences.add(s.substring(last, m.start()))
            last = m.end()
        }
        sentences.add(s.substring(last))
        return sentences
            .map { it.replace("<<DOT>>", ".").trim() }
            .filter { it.isNotEmpty() }
    }

    private fun batchSentences(sentences: List<String>, targetChars: Int): List<String> {
        if (sentences.isEmpty()) return emptyList()
        val batches = ArrayList<String>()
        var current = ""
        for (s in sentences) {
            if (current.length + s.length + 1 > targetChars && current.isNotEmpty()) {
                batches.add(current)
                current = s
            } else {
                current = if (current.isEmpty()) s else "$current $s"
            }
        }
        if (current.isNotEmpty()) batches.add(current)
        return batches
    }

    private fun normalizeKey(text: String): String = collapseWhitespace(text.lowercase())

    /** Splits into word tokens (letters/digits/apostrophes) and single-char punctuation tokens. */
    private fun tokenize(s: String): List<String> {
        val tokens = ArrayList<String>()
        val current = StringBuilder()
        fun flush() {
            if (current.isNotEmpty()) {
                tokens.add(current.toString())
                current.setLength(0)
            }
        }
        for (ch in s) {
            when {
                ch.isLetter() || ch.isDigit() || ch == '\'' || ch == '’' -> current.append(ch)
                ch.isWhitespace() -> flush()
                else -> { flush(); tokens.add(ch.toString()) }
            }
        }
        flush()
        return tokens
    }

    private val spaceBeforePunct = Pattern.compile("\\s+([,\\.!\\?:;)\\]\\}])")
    private val punctNoSpace = Pattern.compile("([,\\.!\\?:;])([^\\s\\)\\]\\}])")
    private val openBracketSpace = Pattern.compile("([\\(\\[\\{])\\s+")

    private fun finalize(s: String): String {
        var out = s
        // English doesn't use inverted punctuation
        out = out.replace("¿", "").replace("¡", "")
        out = spaceBeforePunct.matcher(out).replaceAll("$1")
        out = punctNoSpace.matcher(out).replaceAll("$1 $2")
        out = openBracketSpace.matcher(out).replaceAll("$1")
        out = collapseWhitespace(out)
        // Capitalize sentence starts
        val chars = out.toCharArray()
        if (chars.isNotEmpty() && chars[0].isLetter()) chars[0] = chars[0].titlecaseChar()
        var i = 1
        while (i < chars.size) {
            val prev = chars[i - 1]
            if (prev == '.' || prev == '!' || prev == '?') {
                var j = i
                while (j < chars.size && chars[j].isWhitespace()) j += 1
                if (j < chars.size && chars[j].isLetter()) chars[j] = chars[j].titlecaseChar()
                // j can equal i when punctuation is followed by a non-letter,
                // non-space char (e.g. ".)"), so always advance past it.
                i = j + 1
            } else {
                i += 1
            }
        }
        return String(chars)
    }

    // ------------------------------------------------------------------
    // Data loading (streaming JSON — the decompressed file is ~27 MB)
    // ------------------------------------------------------------------

    private fun loadFrom(reader: JsonReader): Unit {
        val newDict = HashMap<String, String>(300_000)
        val newPos = HashMap<String, String>(60_000)
        var rulesBag: Map<String, Any?> = emptyMap()

        reader.beginObject()
        while (reader.hasNext()) {
            when (reader.nextName()) {
                "dictionary" -> readDictionary(reader, newDict, newPos)
                "rules" -> {
                    @Suppress("UNCHECKED_CAST")
                    rulesBag = (readAny(reader) as? Map<String, Any?>) ?: emptyMap()
                }
                // "version", "generated" and the top-level "phrases" key are ignored,
                // matching the Swift decoder (ESMaster only reads _metadata/dictionary/rules).
                else -> reader.skipValue()
            }
        }
        reader.endObject()

        // --- reflexive passives (absent in the current data file; kept for parity) ---
        val reflexives = HashMap<String, String>()
        (rulesBag["reflexive_passives"])?.let { raw ->
            asStringMap(raw)?.forEach { (k, v) ->
                reflexives[collapseWhitespace(k.lowercase())] = v
            }
        }

        // --- JSON regex rules, bucketed by name/description heuristics (also absent today) ---
        val gen = ArrayList<Rule>()
        val diaJSON = ArrayList<Rule>()
        val gra = ArrayList<Rule>()
        val cle = ArrayList<Rule>()
        val rawRR = rulesBag["regex_rules"] ?: rulesBag["regex"]
        if (rawRR is List<*>) {
            for (objAny in rawRR) {
                val obj = objAny as? Map<*, *> ?: continue
                val pattern = obj["pattern"] as? String ?: continue
                val replace = obj["replace"] as? String ?: continue
                if ((obj["enabled"] as? Boolean) == false) continue
                val optsArray = (obj["options"] as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                var flags = 0
                if (optsArray.contains("i")) flags = flags or Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE
                if (optsArray.contains("m")) flags = flags or Pattern.MULTILINE
                if (optsArray.contains("s")) flags = flags or Pattern.DOTALL
                // NSRegularExpression templates use $1 like java.util.regex — pass through.
                val re = try { Pattern.compile(pattern, flags) } catch (e: Exception) { continue }
                val name = ((obj["name"] as? String ?: "") + " " + (obj["description"] as? String ?: "")).lowercase()
                when {
                    name.contains("dialogue") || name.contains("quote") || pattern.contains("—") -> diaJSON.add(Rule(re, replace))
                    name.contains("grammar") || name.contains("verb") || name.contains("tense") -> gra.add(Rule(re, replace))
                    name.contains("cleanup") || name.contains("space") || name.contains("punct") -> cle.add(Rule(re, replace))
                    else -> gen.add(Rule(re, replace))
                }
            }
        }

        // --- Phrase matcher: RULES buckets FIRST, then multiword dictionary entries fill gaps ---
        val phraseSource = HashMap<String, String>()
        phraseSource.putAll(collectRulePhrases(rulesBag)) // rules win on conflict (put first)
        for ((k, v) in newDict) {
            if (k.contains(' ') && !phraseSource.containsKey(k)) phraseSource[k] = v
        }
        val matcher = if (phraseSource.isEmpty()) null else PhraseMatcher(phraseSource)

        // --- Precompile reflexive patterns ---
        val reflexiveCompiled = ArrayList<Rule>(reflexives.size)
        for ((k, v) in reflexives) {
            val pat = "\\b" + Pattern.quote(k) + "\\b"
            try {
                // Swift passes the value as a replacement TEMPLATE ($1 etc.) — keep it raw.
                reflexiveCompiled.add(Rule(Pattern.compile(pat, CI), v))
            } catch (ignored: Exception) {
            }
        }

        // --- Publish (before isLoaded flips in load()) ---
        dict = newDict
        posMap = newPos
        phraseMatcher = matcher
        reflexiveRules = reflexiveCompiled
        compiledGeneral = gen
        compiledDialogueFromJSON = diaJSON
        compiledGrammar = gra
        compiledCleanup = cle

        val packs = compileBuiltinRules()
        builtinPriceAndUnits = packs.priceUnits
        builtinAlInfinitivo = packs.alInf
        builtinPrepositions = packs.preps
        builtinMenuLexicon = packs.menuLex
        builtinNarrativeGrammar = packs.narrative
        builtinDialogue = packs.dialogue
    }

    /** Streams the huge "dictionary" object without building a generic tree. */
    private fun readDictionary(
        reader: JsonReader,
        outDict: HashMap<String, String>,
        outPos: HashMap<String, String>,
    ) {
        reader.beginObject()
        while (reader.hasNext()) {
            val key = reader.nextName().lowercase()
            var translation: String? = null
            var pos: String? = null
            if (reader.peek() == JsonToken.BEGIN_OBJECT) {
                reader.beginObject()
                while (reader.hasNext()) {
                    when (reader.nextName()) {
                        "translation" -> translation =
                            if (reader.peek() == JsonToken.STRING) reader.nextString() else { reader.skipValue(); null }
                        "pos" -> pos =
                            if (reader.peek() == JsonToken.STRING) reader.nextString() else { reader.skipValue(); null }
                        else -> reader.skipValue() // lemma/morph unused by the engine (parity w/ Swift)
                    }
                }
                reader.endObject()
            } else {
                reader.skipValue()
            }
            if (!translation.isNullOrEmpty()) outDict[key] = translation
            // POS tags power the noun-adjective reorder pass
            if (pos == "NOUN" || pos == "ADJ" || pos == "ADV" || pos == "VERB") outPos[key] = pos
        }
        reader.endObject()
    }

    /** Generic JSON value reader for the (small) "rules" subtree. */
    private fun readAny(reader: JsonReader): Any? = when (reader.peek()) {
        JsonToken.BEGIN_OBJECT -> {
            val m = LinkedHashMap<String, Any?>()
            reader.beginObject()
            while (reader.hasNext()) m[reader.nextName()] = readAny(reader)
            reader.endObject()
            m
        }
        JsonToken.BEGIN_ARRAY -> {
            val l = ArrayList<Any?>()
            reader.beginArray()
            while (reader.hasNext()) l.add(readAny(reader))
            reader.endArray()
            l
        }
        JsonToken.STRING -> reader.nextString()
        JsonToken.NUMBER -> reader.nextDouble()
        JsonToken.BOOLEAN -> reader.nextBoolean()
        JsonToken.NULL -> { reader.nextNull(); null }
        else -> { reader.skipValue(); null }
    }

    /** Swift's `as? [String: String]` cast succeeds only if EVERY value is a String. */
    private fun asStringMap(raw: Any?): Map<String, String>? {
        val m = raw as? Map<*, *> ?: return null
        val out = HashMap<String, String>(m.size)
        for ((k, v) in m) {
            if (k !is String || v !is String) return null
            out[k] = v
        }
        return out
    }

    /**
     * Collects src->tgt phrases from every rules bucket that is either a map of
     * all-string values or an array of all-string maps with "src"/"tgt" keys —
     * mirroring Swift collectRulePhrases (including the quirk that any all-string
     * bucket, e.g. "metadata", contributes entries; they never match real text).
     */
    private fun collectRulePhrases(dicts: Map<String, Any?>): Map<String, String> {
        val out = HashMap<String, String>()
        for ((_, v) in dicts) {
            val asMap = asStringMap(v)
            if (asMap != null) {
                out.putAll(asMap)
                continue
            }
            val arr = v as? List<*> ?: continue
            // Swift's [[String: String]] cast: every row must be an all-string map.
            val rows = arr.map { asStringMap(it) }
            if (rows.isEmpty() || rows.any { it == null }) continue
            for (row in rows) {
                val k = row!!["src"] ?: continue
                val tgt = row["tgt"] ?: continue
                out[k] = tgt
            }
        }
        return out
    }

    // ------------------------------------------------------------------
    // Built-in deterministic rules (ported verbatim from Swift)
    // ------------------------------------------------------------------

    private class Packs(
        val priceUnits: List<Rule>,
        val alInf: List<Rule>,
        val preps: List<Rule>,
        val menuLex: List<Rule>,
        val narrative: List<Rule>,
        val dialogue: List<Rule>,
    )

    private fun rulePack(pairs: List<Pair<String, String>>): List<Rule> =
        pairs.mapNotNull { (p, r) ->
            try { Rule(Pattern.compile(p, CI), r) } catch (e: Exception) { null }
        }

    private fun compileBuiltinRules(): Packs {
        val priceUnits = rulePack(listOf(
            "(\\d+)\\s*(€|euros?)\\s+el\\s+kilo" to "$1$2 per kilo",
            "(\\d+)\\s*(€|euros?)\\s+la\\s+docena" to "$1$2 per dozen",
            "(\\d+)\\s*(€|euros?)\\s+cada\\s+uno" to "$1$2 each",
            "\\bto fifteen euros the kilo\\b" to "for fifteen euros a kilo",
        ))

        // "al + infinitivo" -> "upon <gerund>"
        val alInf = rulePack(listOf(
            "\\bal\\s+([a-záéíóúñ]+)r\\b" to "upon $1ing",
        ))

        // Preposition/cleanup fixes (general)
        val preps = rulePack(listOf(
            "\\brealized of\\b" to "realized",
            "\\brealized of that\\b" to "realized that",
            "\\bbrought of the field\\b" to "brought from the countryside",
            "\\bbrought of\\b" to "brought from",
            "\\bto the enter\\b" to "upon entering",
            "\\bmirror in the floor\\b" to "mirror on the ground",
            "\\bas the rain I created\\b" to "as the rain created",
            "\\bunder the awning of a little coffee\\b" to "under the awning of a small café",
            "\\brestaurant of to the side\\b" to "next-door restaurant",
            "\\bOctopos\\b" to "octopus",
            "\\boctopos\\b" to "octopus",
            // English article agreement after reordering ("a old man" -> "an old man")
            "\\ba ([aeiou])" to "an $1",
            "\\bA ([aeiou])" to "An $1",
        ))

        // Menu lexicon tweaks (English-side)
        val menuLex = rulePack(listOf(
            "\\bPosts of\\b" to "stalls of",
            "\\bstalls of fruit\\b" to "fruit stalls",
            "\\bpuestos de\\s+([a-záéíóúñ]+)\\b" to "$1 stalls",
            "\\bpremises\\b" to "locals",
        ))

        // Narrative grammar/idiom targets
        val narrative = rulePack(listOf(
            "(?m)^Is a\\b" to "It's a",
            "\\bhe can find of all\\b" to "you can find everything",
            "\\bof all\\b" to "everything",
            "\\bthere was a lot people\\b" to "there were a lot of people",
            "\\bso (?:much|many)\\s+tourists as\\b" to "as many tourists as",
            "\\bPosts of\\b" to "stalls of",
            "\\ba Sir elderly\\b" to "an elderly man",
            "\\bmoustache\\b" to "mustache",
            "\\bproof this\\b" to "try this",
            "\\bis of acorn-fed\\b" to "is acorn-fed",
            "\\bthe buys of all the week\\b" to "the shopping for the whole week",
            "\\bI would be a day perfect\\b" to "It would be a perfect day",
            "\\bfor lose\\b" to "to lose",
            "\\bstreets old\\b" to "old streets",
            "\\bAfter of\\b" to "After",
            "\\bbreakfast fast\\b" to "quick breakfast",
            "\\bThis\\s+Fill of\\b" to "It's filled with",
            "\\bpeppers\\s+Red\\b" to "red peppers",
            "\\ba cluster of musicians street\\b" to "a group of street musicians",
            "\\bdrawer flamenco\\b" to "cajón flamenco",
            "\\bFollowing the rhythm\\b" to "clapping along to the rhythm",
            "\\bsquare central\\b" to "central square",
            "\\bstreet market colorful\\b" to "colorful street market",
            "\\ball guy of things\\b" to "all kinds of things",
            "\\bblankets\\s+tejidas\\s+handmade\\b" to "hand-woven blankets",
            "\\bA women elderly\\b" to "An elderly woman",
            "\\bme told\\b" to "told me",
            "\\bOf soon\\b" to "Suddenly",
            "\\bbegan to rain further strong\\b" to "began to rain harder",
            "\\bThe surf They hit\\b" to "The waves crashed",
            "\\bMe I approached\\b" to "I approached",
            "\\byou I asked\\b" to "I asked him",
            "\\bYeah there was had good fishing\\b" to "if he had a good catch",
            "\\bencogiéndose of shoulders\\b" to "shrugging his shoulders",
            "\\bBefore of go back to home\\b" to "Before heading home",
            "\\bHappens by a\\b" to "I stopped by a",
            "\\bwith he low the arm\\b" to "with it under my arm",
            "\\bEnjoying of the calm\\b" to "enjoying the calm",
            "\\bis left over after of the rain\\b" to "lingers after the rain",
        ))

        // Dialogue: a common Spanish em-dash pattern
        // —Pruébala, chico —me dijo sonriendo—.  ->  "Try it, kid," he said, smiling.
        val dialogue = rulePack(listOf(
            "—\\s*([^—]+?)\\s*—\\s*me dijo sonriendo—\\s*\\." to "\"$1,\" he said, smiling.",
        ))

        return Packs(priceUnits, alInf, preps, menuLex, narrative, dialogue)
    }

    private val CI: Int
        get() = Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE
}
