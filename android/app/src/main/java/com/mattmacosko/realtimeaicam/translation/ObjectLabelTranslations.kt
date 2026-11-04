package com.mattmacosko.realtimeaicam.translation

import java.io.File

/**
 * Object Detection names in Your language (2026-11-04). The detector gives a class number;
 * its English name is translated ONCE per language with the on-device translator (after
 * that language's pack is downloaded), saved to a file, and read from the file from then on:
 * instant and offline.
 *
 * A bare word is ambiguous to a translator ("mouse" the animal or the computer one, "glasses"
 * to see with or to drink from, "stool" to sit on...). [CONTEXT] gives the phrase that is
 * translated instead; a note in brackets is dropped from the answer. The list was built by
 * reading every one of the 601 labels in class_names.txt; iOS uses the same map.
 */
object ObjectLabelTranslations {
    /** Bump when [CONTEXT] changes, so saved files are rebuilt. */
    const val MAP_VERSION = 3

    val CONTEXT: Map<String, String> = mapOf(
        // The list has "Computer mouse" separately, so "Mouse" is the animal.
        "Mouse" to "mouse (animal)",
        "Computer mouse" to "computer mouse",
        "Bat (Animal)" to "bat (flying animal)",
        "Baseball bat" to "baseball bat",
        "Glasses" to "eyeglasses",
        "Wine glass" to "wine glass",
        "Tie" to "necktie",
        "Kite" to "kite (toy)",
        "Orange" to "orange (fruit)",
        "Ruler" to "ruler (measuring tool)",
        "Stool" to "stool (seat)",
        "Watch" to "wristwatch",
        "Scale" to "weighing scale",
        "Tank" to "tank (military vehicle)",
        "Tap" to "water tap",
        "Turkey" to "turkey (bird)",
        "Torch" to "flaming torch",
        "Tick" to "tick (parasite)",
        "Mixer" to "kitchen mixer",
        "Boot" to "boot (footwear)",
        "Bust" to "bust (sculpture)",
        "Fax" to "fax machine",
        "Paddle" to "canoe paddle",
        "Pen" to "ballpoint pen",
        "Cream" to "cream (dairy)",
        "Rose" to "rose (flower)",
        "Sink" to "sink (basin)",
        "Mule" to "mule (animal)",
        "Suit" to "suit (clothing)",
        "Tart" to "tart (pastry)",
        "Chime" to "wind chime",
        "Table" to "table (furniture)",
        "Cart" to "cart (wagon)",
        "Grinder" to "grinder (power tool)",
        "Harbor seal" to "harbor seal",
        "Football" to "football (ball)",
        "Ball" to "ball (toy)",
        "Mechanical fan" to "electric fan",
        "Willow" to "willow tree",
        "Maple" to "maple tree",
        "Jaguar (Animal)" to "jaguar (animal)",
        "Drill (Tool)" to "drill (tool)",
        "Egg (Food)" to "egg (food)",
        "Nail (Construction)" to "nail (construction)",
        "Organ (Musical Instrument)" to "pipe organ",
        "Pitcher (Container)" to "water pitcher",
        "Ratchet (Device)" to "ratchet wrench",
        "Squash (Plant)" to "squash (vegetable)",
        "Volleyball (Ball)" to "volleyball (ball)",
        "Lavender (Plant)" to "lavender (plant)",
        "Rays and skates" to "rays and skates (fish)",
        "Jug" to "jug (container)",
        "Racket" to "racket (sport)",
        "Plant" to "plant (vegetation)",
        "Glove" to "glove (clothing)",
        "Remote control" to "remote control",
        "Ipod" to "iPod",
        "Light bulb" to "light bulb",
        "Microwave oven" to "microwave oven",
        "Tablet computer" to "tablet computer",
    )

    /**
     * Names fixed by hand where the translator gets a kitchen word wrong (2026-11-04, the
     * Cricket: "Mug" came back as the broken "taza de"). A plain cup is "taza"; only a coffee
     * cup the detector sees is just "taza" too (Matt 2026-11-04: it calls every cup "Coffee cup"). Used as is, never sent to the translator.
     */
    val EXACT: Map<String, Map<String, String>> = mapOf(
        "es" to mapOf(
            "Cup" to "taza",
            "Mug" to "taza",
            "Coffee cup" to "taza",
            "Measuring cup" to "taza medidora",
        ),
    )

    /** The hand-fixed name for [label] in [lang], if there is one. */
    fun exactName(label: String, lang: String): String? = EXACT[lang]?.get(label)

    /** The English phrase the translator sees for a label. */
    fun sourcePhrase(label: String): String = CONTEXT[label] ?: label.lowercase()

    /** The translator's answer, without any note in brackets, trimmed. */
    fun cleanOutput(s: String): String =
        s.replace(Regex("""\s*[(（\[][^)）\]]*[)）\]]"""), "").replace(Regex("""\s+"""), " ").trim()

    /** Leading articles a translator adds to a bare noun ("los anteojos", "la souris"): a name is said without one. */
    private val ARTICLES: Map<String, Regex> = mapOf(
        "es" to Regex("^(el|la|los|las|un|una|unos|unas) ", RegexOption.IGNORE_CASE),
        "fr" to Regex("^(le|la|les|un|une|des) |^l['’]", RegexOption.IGNORE_CASE),
        "de" to Regex("^(der|die|das|ein|eine) ", RegexOption.IGNORE_CASE),
        "it" to Regex("^(il|lo|la|i|gli|le|un|uno|una) |^l['’]|^un['’]", RegexOption.IGNORE_CASE),
        "pt" to Regex("^(o|a|os|as|um|uma) ", RegexOption.IGNORE_CASE),
        "nl" to Regex("^(de|het|een) ", RegexOption.IGNORE_CASE),
    )

    /** [cleanOutput], then without a leading article for [lang]. */
    fun cleanOutput(s: String, lang: String): String {
        val c = cleanOutput(s)
        val r = ARTICLES[lang] ?: return c
        return c.replaceFirst(r, "").trim().ifEmpty { c }
    }

    /** Changes when the label list or the context map changes. */
    fun signature(labels: List<String>): String {
        val md = java.security.MessageDigest.getInstance("SHA-256")
        md.update("v$MAP_VERSION\n".toByteArray())
        labels.forEach { md.update(it.toByteArray()); md.update(0) }
        CONTEXT.toSortedMap().forEach { (k, v) -> md.update("$k=$v".toByteArray()); md.update(0) }
        EXACT.toSortedMap().forEach { (lang, names) ->
            names.toSortedMap().forEach { (k, v) -> md.update("$lang:$k=$v".toByteArray()); md.update(0) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }.take(16)
    }

    fun cacheFile(dir: File, lang: String): File = File(dir, "labels_$lang.json")

    /** A small JSON file: {"lang":"es","signature":"…","labels":["…",…]}. */
    fun serialize(lang: String, signature: String, translated: List<String>): String =
        buildString {
            append("{\"lang\":").append(quote(lang))
            append(",\"signature\":").append(quote(signature))
            append(",\"labels\":[")
            translated.forEachIndexed { i, s -> if (i > 0) append(','); append(quote(s)) }
            append("]}")
        }

    /** The saved names, or null when the file is missing, damaged or for another list. */
    fun parse(json: String, lang: String, signature: String, expectedCount: Int): List<String>? {
        val strings = readStrings(json) ?: return null
        // lang, value, signature, value, labels..., in the order serialize writes them.
        if (strings.size < 4 || strings[0] != "lang" || strings[1] != lang || strings[2] != "signature" ||
            strings[3] != signature || strings.getOrNull(4) != "labels"
        ) return null
        val labels = strings.drop(5)
        return if (labels.size == expectedCount) labels else null
    }

    fun load(dir: File, lang: String, labels: List<String>): List<String>? = try {
        val f = cacheFile(dir, lang)
        if (f.exists()) parse(f.readText(), lang, signature(labels), labels.size) else null
    } catch (_: Exception) { null }

    /**
     * Saved names, or translate all of them once with [translate] (English phrase -> answer,
     * null on failure) and save them. Returns null if any label failed, so a half-built list
     * is never saved; the caller keeps English and tries again next time.
     */
    fun loadOrBuild(dir: File, lang: String, labels: List<String>, translate: (String) -> String?): List<String>? {
        load(dir, lang, labels)?.let { return it }
        val out = ArrayList<String>(labels.size)
        for (label in labels) {
            val fixed = exactName(label, lang)
            if (fixed != null) { out.add(fixed); continue }
            val t = translate(sourcePhrase(label)) ?: return null
            out.add(cleanOutput(t, lang).ifEmpty { label.lowercase() })
        }
        try {
            dir.mkdirs()
            val tmp = File(dir, "labels_$lang.json.tmp")
            tmp.writeText(serialize(lang, signature(labels), out))
            tmp.renameTo(cacheFile(dir, lang))
        } catch (_: Exception) {}
        return out
    }

    private fun quote(s: String): String = buildString {
        append('"')
        for (c in s) when (c) {
            '"' -> append("\\\""); '\\' -> append("\\\\"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
            else -> if (c < ' ') append("\\u%04x".format(c.code)) else append(c)
        }
        append('"')
    }

    /** Every JSON string in order (keys and values); enough for the one shape we write. */
    private fun readStrings(json: String): List<String>? {
        val out = ArrayList<String>()
        var i = 0
        while (i < json.length) {
            if (json[i] != '"') { i++; continue }
            val sb = StringBuilder(); i++
            while (true) {
                if (i >= json.length) return null
                val c = json[i]
                if (c == '"') { i++; break }
                if (c == '\\') {
                    if (i + 1 >= json.length) return null
                    when (val e = json[i + 1]) {
                        'n' -> sb.append('\n'); 'r' -> sb.append('\r'); 't' -> sb.append('\t')
                        'u' -> { if (i + 5 >= json.length) return null; sb.append(json.substring(i + 2, i + 6).toInt(16).toChar()); i += 4 }
                        else -> sb.append(e)
                    }
                    i += 2
                } else { sb.append(c); i++ }
            }
            out.add(sb.toString())
        }
        return out
    }
}
