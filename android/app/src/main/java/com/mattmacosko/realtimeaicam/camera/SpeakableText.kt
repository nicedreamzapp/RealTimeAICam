package com.mattmacosko.realtimeaicam.camera

import java.util.concurrent.ConcurrentHashMap
import java.util.regex.Matcher
import java.util.regex.Pattern

/**
 * Rewrites text the camera read so the voice says it the way a person would.
 * The phone's voice guesses at numbers and abbreviations on its own and guesses
 * badly on signs and mail: "393 Westgate Dr" came out "three hundred
 * ninety-three Westgate doctor", a phone number came out as one huge number,
 * and a card number got read in full (Matt, 2026-09-16).
 *
 * Kotlin port of the iOS SpeakableText.swift (project 601), which is the spec.
 *
 * Only what gets SPOKEN goes through this; the text on screen and the text
 * that gets copied stay exactly as the camera read them.
 */
object SpeakableText {

    // Declared first: the patterns below are compiled while the object initializes.
    /**
     * The iPhone uses ICU regexes, where \w, \d, \b and (?i) understand every
     * alphabet. Android's java.util.regex is also ICU underneath, but a desktop
     * JVM (the unit tests) needs UNICODE_CHARACTER_CLASS to behave the same.
     * Some Android versions reject that flag, so only ask for it where it works.
     */
    internal val UNICODE_FLAGS: Int = try {
        Pattern.compile("\\w", Pattern.UNICODE_CHARACTER_CLASS)
        Pattern.UNICODE_CHARACTER_CLASS
    } catch (e: Throwable) {
        0
    }

    private val cache = ConcurrentHashMap<String, Pattern>()

    internal fun re(pattern: String): Pattern =
        cache.getOrPut(pattern) { Pattern.compile(pattern, UNICODE_FLAGS) }

    fun make(input: String): String {
        var s = input
        s = stripFormatting(s)
        s = joinLines(s)
        // "Citation No. 802214557", "Factura No. 004512": "no" would be read as the word.
        s = re("""\b[Nn][Oo]\.\s*(?=#?\s?\d)""").matcher(s).replaceAll("number ")
        s = tooLongToSay(s)
        s = maskedNumbers(s)
        s = europeanAmounts(s)
        s = internationalPrefix(s)
        s = phoneNumbers(s)
        s = zipCodes(s)
        s = poBox(s)
        s = streetAddresses(s)
        s = unitWords(s)
        s = monthYear(s)
        s = mixedCodes(s)
        s = labeledNumbers(s)
        s = digitRuns(s)
        s = fractions(s)
        // "TR# 7731", "Order #12": the voice may say "pound" or "hashtag".
        s = s.replace("#", " number ")
        s = re("""[ \t]{2,}""").matcher(s).replaceAll(" ")
        s = re("""\s+([,.:;])""").matcher(s).replaceAll("$1")
        s = re("""(?:,\s*){2,}""").matcher(s).replaceAll(", ")
        return s.trim()
    }

    /**
     * Object-detection labels as a person would say them: "Bat (Animal)" was
     * read out with its label note, "Kitchen & dining room table" with its
     * ampersand. Returns just "bat", "kitchen and dining room table".
     */
    fun className(name: String): String =
        re("""\s*\([^)]*\)""").matcher(name).replaceAll("")
            .replace("&", "and")
            .lowercase()

    // ---- Formatting ----

    /**
     * Things with no business coming out of a speaker: the model's markdown
     * ("**Due:**", "- item", "## Bill"), emoji, dot leaders and rule lines on
     * menus and receipts ("Burger.......14.50", "=========="), and the path
     * part of a web address ("ineedhemp.com/how-to-clean-..." is read slash by slash).
     */
    fun stripFormatting(s: String): String {
        var out = s
        out = re("""\*\*(.+?)\*\*""").matcher(out).replaceAll("$1")
        out = re("""__(.+?)__""").matcher(out).replaceAll("$1")
        out = re("""(?m)^\s*#{1,6}\s+""").matcher(out).replaceAll("")
        out = re("""(?m)^\s*(?:[-*•▪◦·]|\d{1,2}[.)])\s+""").matcher(out).replaceAll("")
        out = re("""`+""").matcher(out).replaceAll("")
        // Emoji and pictographs (keeps letters, digits, punctuation, currency).
        val sb = StringBuilder(out.length)
        var i = 0
        while (i < out.length) {
            val cp = out.codePointAt(i)
            if (!isPictograph(cp)) sb.appendCodePoint(cp)
            i += Character.charCount(cp)
        }
        out = sb.toString()
        // Web addresses: say the site, not the path.
        out = replace(out, """(?i)\b(?:https?://)?(?:www\.)?((?:[a-z0-9-]+\.)+(?:com|org|net|gov|edu|io|co|us|mx|es|app|ai)\b)(?:/[^\s]*)?""") { m ->
            val site = m.group(0) ?: ""
            if (m.whole.contains("/")) "$site link" else m.whole
        }
        // Dot leaders and rule lines are a pause.
        out = re("""\s*(?:\.\s?){3,}\s*(?=\S)""").matcher(out).replaceAll(", ")
        out = re("""[-=_~]{3,}|\*{3,}(?![*\s]*\d)""").matcher(out).replaceAll(" ")
        return out
    }

    /**
     * Swift's `isEmojiPresentation || (isEmoji && > U+2000)`, plus the variation
     * selector and zero-width joiner. The emoji property tables aren't available
     * on every Android version or on the JVM, so the ranges are listed here
     * (Unicode emoji-data, Emoji=Yes, above U+2000).
     */
    private val emojiRanges = intArrayOf(
        0x203C, 0x203C, 0x2049, 0x2049, 0x2122, 0x2122, 0x2139, 0x2139,
        0x2194, 0x2199, 0x21A9, 0x21AA, 0x231A, 0x231B, 0x2328, 0x2328,
        0x23CF, 0x23CF, 0x23E9, 0x23F3, 0x23F8, 0x23FA, 0x24C2, 0x24C2,
        0x25AA, 0x25AB, 0x25B6, 0x25B6, 0x25C0, 0x25C0, 0x25FB, 0x25FE,
        0x2600, 0x2604, 0x260E, 0x260E, 0x2611, 0x2611, 0x2614, 0x2615,
        0x2618, 0x2618, 0x261D, 0x261D, 0x2620, 0x2620, 0x2622, 0x2623,
        0x2626, 0x2626, 0x262A, 0x262A, 0x262E, 0x262F, 0x2638, 0x263A,
        0x2640, 0x2640, 0x2642, 0x2642, 0x2648, 0x2653, 0x265F, 0x2660,
        0x2663, 0x2663, 0x2665, 0x2666, 0x2668, 0x2668, 0x267B, 0x267B,
        0x267E, 0x267F, 0x2692, 0x2697, 0x2699, 0x2699, 0x269B, 0x269C,
        0x26A0, 0x26A1, 0x26A7, 0x26A7, 0x26AA, 0x26AB, 0x26B0, 0x26B1,
        0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26C8, 0x26C8, 0x26CE, 0x26CF,
        0x26D1, 0x26D1, 0x26D3, 0x26D4, 0x26E9, 0x26EA, 0x26F0, 0x26F5,
        0x26F7, 0x26FA, 0x26FD, 0x26FD, 0x2702, 0x2702, 0x2705, 0x2705,
        0x2708, 0x270D, 0x270F, 0x270F, 0x2712, 0x2712, 0x2714, 0x2714,
        0x2716, 0x2716, 0x271D, 0x271D, 0x2721, 0x2721, 0x2728, 0x2728,
        0x2733, 0x2734, 0x2744, 0x2744, 0x2747, 0x2747, 0x274C, 0x274C,
        0x274E, 0x274E, 0x2753, 0x2755, 0x2757, 0x2757, 0x2763, 0x2764,
        0x2795, 0x2797, 0x27A1, 0x27A1, 0x27B0, 0x27B0, 0x27BF, 0x27BF,
        0x2934, 0x2935, 0x2B05, 0x2B07, 0x2B1B, 0x2B1C, 0x2B50, 0x2B50,
        0x2B55, 0x2B55, 0x3030, 0x3030, 0x303D, 0x303D, 0x3297, 0x3297,
        0x3299, 0x3299,
        0x1F004, 0x1F004, 0x1F0CF, 0x1F0CF, 0x1F170, 0x1F19A,
        0x1F1E6, 0x1F1FF, 0x1F201, 0x1F251, 0x1F300, 0x1FAFF,
    )

    private fun isPictograph(cp: Int): Boolean {
        if (cp == 0xFE0F || cp == 0x200D) return true
        if (cp <= 0x2000) return false
        var k = 0
        while (k < emojiRanges.size) {
            if (cp < emojiRanges[k]) return false
            if (cp <= emojiRanges[k + 1]) return true
            k += 2
        }
        return false
    }

    // ---- Lines ----

    /**
     * A new line on a sign or an envelope is a pause, not a run-on. Without
     * it "Westgate Dr" and "Eureka, CA" on the next line blur together.
     */
    fun joinLines(s: String): String {
        val lines = s.split(NEWLINES)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        if (lines.size <= 1) return lines.firstOrNull() ?: ""
        val out = StringBuilder()
        for ((i, line) in lines.withIndex()) {
            out.append(line)
            if (i < lines.size - 1) {
                out.append(if (".,;:!?".contains(line.last())) " " else ", ")
            }
        }
        return out.toString()
    }

    private val NEWLINES = Regex("[\\n\\r\\u000B\\u000C\\u0085\\u2028\\u2029]")

    // ---- Numbers ----

    private val digitWords = listOf(
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    )
    private val teens = listOf(
        "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    )
    private val tens = listOf(
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    )

    private fun digitValue(c: Char): Int = Character.digit(c, 10)

    /** "805" -> "eight zero five" */
    fun spelled(digits: CharSequence): String =
        digits.mapNotNull { c -> digitValue(c).takeIf { it >= 0 } }
            .joinToString(" ") { digitWords[it] }

    fun twoDigit(n: Int): String {
        if (n < 10) return digitWords[n]
        if (n < 20) return teens[n - 10]
        return if (n % 10 == 0) tens[n / 10] else "${tens[n / 10]}-${digitWords[n % 10]}"
    }

    /**
     * House numbers the way people say them: 393 "three ninety-three",
     * 1205 "twelve oh five", 2000 "two thousand", 45120 "four five one two zero".
     */
    fun houseNumber(digits: String): String {
        val n = digits.toIntOrNull() ?: return digits
        // "Tienda 0147": the zero is part of the name, say every digit.
        if (digits.length > 1 && digits.startsWith("0")) return spelled(digits)
        return when (digits.length) {
            1, 2 -> twoDigit(n)
            3 -> {
                val hi = n / 100
                val lo = n % 100
                when {
                    lo == 0 -> "${digitWords[hi]} hundred"
                    lo < 10 -> "${digitWords[hi]} oh ${digitWords[lo]}"
                    else -> "${digitWords[hi]} ${twoDigit(lo)}"
                }
            }
            4 -> {
                val hi = n / 100
                val lo = n % 100
                when {
                    n % 1000 == 0 -> "${digitWords[n / 1000]} thousand"
                    lo == 0 -> "${twoDigit(hi)} hundred"
                    lo < 10 -> "${twoDigit(hi)} oh ${digitWords[lo]}"
                    else -> "${twoDigit(hi)} ${twoDigit(lo)}"
                }
            }
            else -> spelled(digits)
        }
    }

    /**
     * The most digits worth reading out loud. Past this (tracking barcodes,
     * serials) nobody follows along; the copy on screen has them all.
     */
    const val MAX_SPOKEN_DIGITS = 16

    private fun digitCount(s: CharSequence) = s.count { it.isDigit() }
    private fun alnum(s: CharSequence) = s.filter { it.isLetter() || it.isDigit() }

    /**
     * More than 16 digits in a row, or a code longer than 16 characters:
     * skip it and just say "long number" so the person knows something is there.
     */
    fun tooLongToSay(s: String): String {
        var out = replace(s, """(?<![\w$.,])\d(?:[ -]?\d)+(?![\w]|[.,]\d)""") { m ->
            if (digitCount(m.whole) > MAX_SPOKEN_DIGITS) "long number" else m.whole
        }
        out = replace(out, """\b(?=[A-Z0-9-]*\d)(?=[A-Z0-9-]*[A-Z])[A-Z0-9][A-Z0-9-]{16,}\b""") { m ->
            val chars = alnum(m.whole)
            if (chars.length > MAX_SPOKEN_DIGITS && digitCount(chars) >= 3) "long number" else m.whole
        }
        // Printed in spaced chunks, UPS style: "1Z 999 AA1 01 2345 6784".
        out = replace(out, """\b[A-Z0-9]{1,6}(?:[ -][A-Z0-9]{1,6}){2,}\b""") { m ->
            val chars = alnum(m.whole)
            if (chars.length > MAX_SPOKEN_DIGITS && digitCount(chars) >= 10) "long number" else m.whole
        }
        return out
    }

    /**
     * Spanish and European money: "1.234,56 €" -> "1,234.56 €", "214,26 €" ->
     * "214.26 €", "1.500.000" -> "1,500,000". Only shapes that can't be
     * American: a dot every three digits, or a two-digit comma before €.
     */
    fun europeanAmounts(s: String): String {
        var out = replace(s, """(?<![\d.,])(\d{1,3}(?:\.\d{3})+)(?:,(\d{1,2}))?(?![\d.,]*\d)""") { m ->
            val g0 = m.group(0) ?: ""
            val cents = m.group(1)
            val whole = g0.replace(".", ",")
            // "1.234" alone could be American 1.234; needs two groups or cents.
            if (cents == null && g0.count { it == '.' } < 2) {
                m.whole
            } else if (cents != null) {
                "$whole.$cents"
            } else {
                whole
            }
        }
        out = replace(out, """(?<![\d.,])(\d+),(\d{2})(?=\s?(?:€|EUR|euros?\b))""") { m ->
            "${m.group(0) ?: ""}.${m.group(1) ?: ""}"
        }
        return out
    }

    /** "+34 912 345 678" -> "plus three four, nine one two, ..." */
    fun internationalPrefix(s: String): String =
        replace(s, """\+\s?(\d{1,3})(?=[ .-]\d)""") { m -> "plus ${spelled(m.group(0) ?: "")}, " }

    /**
     * Masked numbers: "****4471", "XXX-XX-6789" -> "ending in four four seven one".
     * A mask with nothing after it isn't said at all ("star star star...").
     * "Checking ending in 4471" gets its last four as digits too.
     */
    fun maskedNumbers(s: String): String {
        var out = replace(s, """(?:[*•]{2,}|\bX{2,})(?:[ -]?(?:[*•]+|X+))*[ -]?(\d{2,4})\b""") { m ->
            "ending in ${spelled(m.group(0) ?: "")}"
        }
        out = replace(out, """[*•]{3,}""") { "" }
        out = replace(out, """(?i)\b(ending in|ends in|last four|last 4)(:?\s*)(\d{4})\b""") { m ->
            "${m.group(0) ?: ""} ${spelled(m.group(2) ?: "")}"
        }
        return out
    }

    /**
     * (707) 555-0142, 805-895-8967, 805.895.8967, 1-800-555-1234, +1 707 555 0142
     * -> "eight zero five, eight nine five, eight nine six seven"
     */
    fun phoneNumbers(s: String): String {
        val pattern = """(?<![\w$])(?:\+?(1)[ .-]?)?\(?(\d{3})\)?[ .-]?(\d{3})[ .-](\d{4})(?!\w)"""
        return replace(s, pattern) { m ->
            val said = ArrayList<String>()
            val one = m.group(0)
            if (!one.isNullOrEmpty()) said.add("one")
            for (i in 1 until m.groupCount) m.group(i)?.let { said.add(spelled(it)) }
            said.joinToString(", ")
        }
    }

    private const val STATES =
        "AL|AK|AZ|AR|CA|CO|CT|DE|DC|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|PR"

    /**
     * "CA 95501" -> "C A, nine five five zero one". The state letters are
     * spaced out because "CA" alone sometimes comes out as a word.
     */
    fun zipCodes(s: String): String =
        replace(s, """\b($STATES)\.?,?\s+(\d{5})(?:-(\d{4}))?\b""") { m ->
            val state = (m.group(0) ?: "").toList().joinToString(" ")
            var out = "$state, ${spelled(m.group(1) ?: "")}"
            m.group(2)?.let { out += ", ${spelled(it)}" }
            out
        }

    fun poBox(s: String): String =
        replace(s, """(?i)\bP\.?\s?O\.?\s+Box\s+(\d+)""") { m ->
            "P O Box ${houseNumber(m.group(0) ?: "")}"
        }

    private val suffixes = mapOf(
        "dr" to "Drive", "st" to "Street", "ave" to "Avenue", "av" to "Avenue", "blvd" to "Boulevard",
        "rd" to "Road", "ln" to "Lane", "ct" to "Court", "pl" to "Place", "pkwy" to "Parkway",
        "hwy" to "Highway", "cir" to "Circle", "ter" to "Terrace", "trl" to "Trail", "sq" to "Square",
        "cres" to "Crescent", "expy" to "Expressway", "fwy" to "Freeway", "hts" to "Heights",
    )
    private val directions = mapOf(
        "n" to "North", "s" to "South", "e" to "East", "w" to "West",
        "ne" to "Northeast", "nw" to "Northwest", "se" to "Southeast", "sw" to "Southwest",
    )
    private val suffixAlt: String = suffixes.keys
        .sortedWith(compareByDescending<String> { it.length }.thenBy { it })
        .joinToString("|")

    /**
     * "393 Westgate Dr" -> "three ninety-three Westgate Drive"
     * "1205 N Main St." -> "twelve oh five North Main Street"
     */
    fun streetAddresses(s: String): String {
        val pattern = """(?i)\b(\d{1,6})([A-Z])?\s+(?:(N|S|E|W|NE|NW|SE|SW)\.?\s+)?((?:[A-Z0-9][\w'-]*\s+){0,3}?(?:[A-Z][\w'-]*|\d+(?:st|nd|rd|th)))\s+($suffixAlt)\b\.?(?:\s+(N|S|E|W|NE|NW|SE|SW)\b\.?)?"""
        var out = replace(s, pattern) { m ->
            // "Room 12 with Dr Smith" is not an address: real street names are
            // capitalized. All-caps signs pass because they have no lowercase.
            val name = m.group(3) ?: ""
            if (name.split(' ').any { it.firstOrNull()?.isLowerCase() == true }) {
                return@replace m.whole
            }
            var said = houseNumber(m.group(0) ?: "")
            m.group(1)?.let { said += " ${it.uppercase()}" }
            m.group(2)?.let { d -> directions[d.lowercase()]?.let { said += " $it" } }
            said += " $name"
            m.group(4)?.let { suf -> suffixes[suf.lowercase()]?.let { said += " $it" } }
            m.group(5)?.let { d -> directions[d.lowercase()]?.let { said += " $it" } }
            said
        }
        // No house number but clearly a street: "Westgate Dr," / "Main St" at
        // the end of a line. "Dr. Smith" still gets to be a doctor.
        out = replace(out, """\b([A-Z][A-Za-z'-]+|\d+(?:st|nd|rd|th|ST|ND|RD|TH))\s+(Dr|DR|St|ST|Ave|AVE|Blvd|BLVD|Rd|RD|Ln|LN)\b\.?(?=\s*(?:[,;]|$))""") { m ->
            val suf = m.group(1) ?: ""
            val word = suffixes[suf.lowercase()] ?: suf
            "${m.group(0) ?: ""} $word"
        }
        return out
    }

    private val unitNames = mapOf(
        "apt" to "Apartment", "ste" to "Suite", "suite" to "Suite",
        "unit" to "Unit", "bldg" to "Building", "fl" to "Floor",
    )

    /** Apt 4B, Ste 200, Unit 12, # 7 after an address */
    fun unitWords(s: String): String =
        replace(s, """(?i)\b(apt|ste|suite|unit|bldg|fl)\b\.?\s*#?\s*(\d+)([A-Z])?\b""") { m ->
            var said = "${unitNames[(m.group(0) ?: "").lowercase()] ?: ""} ${houseNumber(m.group(1) ?: "")}"
            m.group(2)?.let { said += " ${it.uppercase()}" }
            said
        }

    /**
     * A short number with a label in front is a name, not a quantity:
     * "Store 1847" and "TR# 7731" say "eighteen forty-seven", "seventy-seven
     * thirty-one", not "one thousand eight hundred forty-seven".
     */
    fun labeledNumbers(s: String): String {
        val labels = """#|No\.?|Number|Num\.?|Store|Flight|Flt\.?|Room|Rm\.?|Ext\.?|Order|Ticket|Invoice|Inv\.?|Gate|Bus|Route|Train|Check|Lot|Case|Claim|Unit|Space|Stall|Box|Locker|Table|Seat|Station"""
        return replace(s, """(?i)\b((?:$labels)\s*#?\s*:?\s*)(?:([A-Z]{2})\s)?(\d{3,4})(?![\w%]|[.,:/]\d)""") { m ->
            val code = m.group(1)?.let { "$it " } ?: ""
            "${m.group(0) ?: ""}$code${houseNumber(m.group(2) ?: "")}"
        }
    }

    /** Dates keep their normal reading ("9/16/2026", "2026-09-16"). */
    private val dateShape = re("""^(?:\d{1,2}[-/]\d{1,2}[-/]\d{2,4}|\d{4}-\d{1,2}-\d{1,2})$""")

    /**
     * Anything that is an ID rather than an amount gets its digits read one at a
     * time, keeping the groups it was printed in as pauses:
     * "Order #203041" -> "number two zero three zero four one",
     * "9400 1118 9922 3344" -> "nine four zero zero, one one one eight, ...".
     * Amounts (commas, decimals, $), years and short numbers are left alone,
     * and so are loose small numbers in a row ("Qty 2 12 50").
     */
    fun digitRuns(s: String): String =
        replace(s, """(?<![\w$.,:/])(#\s?)?(\d+(?:[ -]\d+)*)(?![\w%]|[.,:/]\d)""") { m ->
            val run = m.group(1) ?: ""
            val prefix = if (m.group(0) == null) "" else "# "
            if (dateShape.matcher(run).find()) return@replace m.whole
            val groups = run.split(' ', '-').filter { it.isNotEmpty() }
            val total = groups.sumOf { it.length }
            val bigGroups = groups.count { it.length >= 3 }
            // One printed block of 5+ digits, or several blocks that together read
            // as one ID: "4491027735-6", "94-3217765", or 3+ digit blocks, 8+ in all.
            val isID = if (groups.size == 1) {
                total >= 5
            } else {
                (bigGroups >= 2 && total >= 8) || groups.any { it.length >= 5 }
            }
            if (isID && total <= MAX_SPOKEN_DIGITS) {
                prefix + groups.joinToString(", ") { spelled(it) }
            } else {
                // Not an ID ("Pages 3-5", "Qty 2 12 50"): leave it as printed.
                m.whole
            }
        }

    val monthNames = listOf(
        "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December",
    )

    /**
     * Card expiry and use-by dates: "VALID THRU 04/28" -> "April 2028",
     * "Exp 09/2027" -> "September 2027". A bare "04/28" elsewhere is left alone
     * (it could be a day). "18:00 hrs" drops the "hrs": the voice already says hours.
     */
    fun monthYear(s: String): String {
        var out = replace(s, """(?<![\d/])(0?[1-9]|1[0-2])/(20\d{2})(?![\d/])""") { m ->
            "${monthNames[(m.group(0) ?: "1").toInt() - 1]} ${m.group(1) ?: ""}"
        }
        out = replace(out, """(?i)\b((?:valid\s+thru|valid\s+through|good\s+thru|exp(?:ires|iration|\.)?|use\s+by|best\s+by)\s*:?\s*)(0?[1-9]|1[0-2])/(\d{2})(?![\d/])""") { m ->
            "${m.group(0) ?: ""}${monthNames[(m.group(1) ?: "1").toInt() - 1]} 20${m.group(2) ?: ""}"
        }
        out = re("""(\d{1,2}:\d{2})\s*(?i:hrs?)\.?(?!\w)""").matcher(out).replaceAll("$1")
        return out
    }

    private val fractionNames = mapOf(
        "1/2" to "one half", "1/3" to "one third", "2/3" to "two thirds", "1/4" to "one quarter",
        "3/4" to "three quarters", "1/8" to "one eighth",
    )

    /** "1/2 tableta" was on its way to "January second". */
    fun fractions(s: String): String {
        val mixed = replace(s, """(?<![\d/.,])(\d+)\s+1/2(?![\d/])""") { m -> "${m.group(0) ?: ""} and a half" }
        return replace(mixed, """(?<![\d/])(\d)/(\d)(?![\d/])""") { m ->
            fractionNames[m.whole] ?: m.whole
        }
    }

    private val unitTail =
        re("""^\d+(?:MG|MCG|ML|G|KG|LB|LBS|OZ|IN|FT|CM|MM|MPH|GB|MB|TB|MAH|W|V|K|AM|PM|ST|ND|RD|TH|X)$""")

    /** "US-101", "I-405", "SR-299" are road names, not codes. */
    private val highway = re("""^(?:US|I|SR|CA|HWY|RT)-\d{1,3}$""")

    /**
     * Codes that mix capital letters and digits: UPS "1Z999AA101234567",
     * "INV-2026-00451", "SN A7B9C2D4E1". Read one character at a time.
     * Needs 3+ digits so "N95", "B12", "4B" and "I-5" stay words.
     */
    fun mixedCodes(s: String): String =
        replace(s, """\b(?=[A-Z0-9-]*\d)(?=[A-Z0-9-]*[A-Z])[A-Z0-9](?:[A-Z0-9]|-(?=[A-Z0-9])){4,}\b""") { m ->
            val code = m.whole
            if (digitCount(alnum(code)) < 3 ||
                highway.matcher(code).find() ||
                unitTail.matcher(code).find()
            ) {
                return@replace code
            }
            code.split('-').filter { it.isNotEmpty() }.joinToString(", ") { part ->
                part.map { c ->
                    val d = digitValue(c)
                    if (d >= 0) digitWords[d] else c.toString()
                }.joinToString(" ")
            }
        }

    // ---- Regex plumbing ----

    /** One regex hit: the whole text and its capture groups (0-based, null when unmatched). */
    class Match(private val m: Matcher) {
        val whole: String = m.group()
        val groupCount: Int = m.groupCount()
        fun group(i: Int): String? = m.group(i + 1)
    }

    fun replace(s: String, pattern: String, transform: (Match) -> String): String {
        val matcher = re(pattern).matcher(s)
        val out = StringBuilder()
        var last = 0
        while (matcher.find()) {
            out.append(s, last, matcher.start())
            out.append(transform(Match(matcher)))
            last = matcher.end()
        }
        out.append(s, last, s.length)
        return out.toString()
    }
}
