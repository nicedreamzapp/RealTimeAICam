package com.mattmacosko.realtimeaicam.aim

import kotlin.math.max
import kotlin.math.min

// MARK: - What else is in view
//
// Port of the second half of iOS `HelpMeAim.swift`. Same rule as the first
// half: the spoken words must match the iPhone exactly.

/**
 * Builds "I don't see a key. I can see a dog, a laptop and a mirror." from the
 * detections already running on each frame (Matt, 2026-09-16). The room scan
 * showed the detector also names rooms and genres with high confidence ("home
 * interior", "tv genre"), so those are filtered out.
 */
object AimElsewhere {
    data class Seen(val name: String, val conf: Float, val box: AimRect)

    // Round 2 (live runs 2026-09-16 still named a boiler and an origami at
    // 0.60): a higher bar, and seen in most of the recent frames.
    const val minConf = 0.70f
    const val minFrames = 3
    const val window = 5
    const val maxThings = 3

    /** Whole names never worth saying. */
    val denylist: Set<String> = setOf(
        "home interior", "playroom", "veterinarians office", "hospital room", "tv genre", "waste",
        "garment", "organization", "floor", "ceiling", "wall", "doorway", "mess", "indoor", "decor",
        "home decor", "collection", "lighting", "comfort", "clothe", "electronic", "fixture", "touch",
        "control", "electricity", "type on", "navratri", "quote", "news", "poetry", "illustration",
        "icon", "oval", "grid", "cube", "swirl", "shadow", "twist", "contain", "bundle", "stack",
        "article", "publication", "character sculpture", "fashion illustration", "line art",
        "studio shot", "car logo", "inscription", "plaid", "velvet", "cotton", "khaki", "granite",
        "beam", "navy", "hospital", "laboratory", "salon", "workplace", "pantry", "alcove", "mantle",
        "entrance hall", "living space", "dressing room", "childs room", "recreation room", "embellishment",
        "animation film", "science fiction film", "firework display", "light show", "wedding reception",
        "art exhibition", "street scene", "hairstyle", "manicure", "pigtail", "braid", "toe", "waist",
        "ear", "hand", "face", "beard", "tail", "claw", "flash", "pad", "capsule", "recycling",
        "boiler", "origami", "waistband", "frame",
    )

    /** Occupations and roles: the detector's guesses about a person, said plainly. */
    val roleWords: Set<String> = setOf(
        "artist", "student", "teacher", "doctor", "nurse", "chef", "worker", "player", "singer",
        "musician", "actor", "actress", "engineer", "scientist", "designer", "technician",
        "researcher", "hacker", "historian", "dentist", "patient", "barber", "photographer",
        "pilot", "officer", "soldier", "farmer", "businessman", "businesswoman", "programmer",
        "writer", "painter", "athlete", "model", "blogger", "gamer", "surgeon", "librarian",
    )

    /** Parts of names that mean a place, a genre or a scene. */
    val deniedFragments = listOf(
        "room", "interior", "office", "genre", "scene", "film", "drama", "studio", "classroom",
        "gym", "shop", "store", "parlor", "mall", "library", "corridor", "hallway", "alley", "hall",
    )

    /** Breeds and people-words said plainly. */
    val collapse: Map<String, String> = mapOf(
        "samoyed" to "dog", "poodle" to "dog", "bichon" to "dog", "golden retriever" to "dog",
        "german shepherd" to "dog", "rottweiler" to "dog", "chihuahua" to "dog", "sheepdog" to "dog",
        "pomeranian" to "dog", "street dog" to "dog", "labrador retriever" to "dog", "labrador" to "dog",
        "beagle" to "dog", "pug" to "dog", "dachshund" to "dog", "husky" to "dog", "puppy" to "dog",
        "guide dog" to "dog", "pet" to "dog",
        "persian cat" to "cat", "american shorthair" to "cat", "siamese cat" to "cat", "kitten" to "cat",
        "tabby cat" to "cat", "ragdoll" to "cat", "maine coon" to "cat",
        "man" to "person", "woman" to "person", "girl" to "person", "boy" to "person",
        "grandfather" to "person", "grandmother" to "person", "cousin" to "person", "daughter" to "person",
        "son" to "person", "newlywed" to "person", "college student" to "person", "patient" to "person",
        "researcher" to "person", "hacker" to "person", "technician" to "person", "historian" to "person",
        "dentist" to "person", "fashion designer" to "person", "child" to "person", "baby" to "person",
        "shelve" to "shelf", "clothe" to "clothes",
        // Live runs 2026-09-16: the detector calls a person these, and the
        // plural class name reads badly in a list.
        "tattoo artist" to "person", "rock artist" to "person", "blue artist" to "person",
        "power plugs and sockets" to "power outlet",
    )

    /** Names said without "a"/"an". */
    val noArticle: Set<String> = setOf(
        "glasses", "sunglasses", "jeans", "shorts", "goggles", "scissors", "headphones", "pants",
        "underdrawers", "clothes", "money", "laundry", "bedding", "linen", "detergent", "duct tape",
    )

    /** The name to say, or null if the class should never be mentioned. */
    fun spokenName(cls: String): String? {
        val name = cls.lowercase().trim()
        if (name.isEmpty() || denylist.contains(name)) return null
        collapse[name]?.let { return it }
        val last = name.split(" ").lastOrNull()
        if (last != null && roleWords.contains(last)) return "person"
        if (deniedFragments.any { name.contains(it) }) return null
        return name
    }

    fun article(name: String): String =
        if (noArticle.contains(name)) name else AimVocabulary.withArticle(name)

    /** Overlapping boxes (IoU > 0.5) keep only the most confident one. */
    fun dedupe(frame: List<Seen>): List<Seen> {
        val kept = ArrayList<Seen>()
        for (s in frame.sortedByDescending { it.conf }) {
            if (kept.none { iou(it.box, s.box) > 0.5f }) kept.add(s)
        }
        return kept
    }

    /**
     * Up to three things, most confident first: said name, confidence at least
     * [minConf], in at least [minFrames] of the recent frames, not the target.
     */
    fun pick(frames: List<List<Seen>>, target: Set<String>): List<String> {
        val best = HashMap<String, Float>()
        val count = HashMap<String, Int>()
        for (frame in frames.takeLast(window)) {
            val inFrame = HashSet<String>()
            for (s in dedupe(frame.filter { it.conf >= minConf })) {
                val name = spokenName(s.name) ?: continue
                if (target.contains(name)) continue
                best[name] = max(best[name] ?: 0f, s.conf)
                inFrame.add(name)
            }
            for (name in inFrame) count[name] = (count[name] ?: 0) + 1
        }
        return best.entries
            .filter { (count[it.key] ?: 0) >= minFrames }
            .sortedWith(compareByDescending<Map.Entry<String, Float>> { it.value }.thenBy { it.key })
            .take(maxThings)
            .map { it.key }
    }

    fun sentence(subject: AimSubject, things: List<String>): String {
        val missing = subject.spokenName
        if (things.isEmpty()) {
            return "I don't see $missing, and nothing else stands out. Try another direction."
        }
        val said = things.map { article(it) }
        val list = when (said.size) {
            1 -> said[0]
            2 -> "${said[0]} and ${said[1]}"
            else -> said.dropLast(1).joinToString(", ") + " and " + said.last()
        }
        return "I don't see $missing. I can see $list."
    }

    /**
     * Names that count as the target itself (so a dog is not offered when
     * looking for a dog).
     */
    fun targetNames(subject: AimSubject): Set<String> = when (subject) {
        is AimSubject.Face -> setOf("person", "face")
        is AimSubject.Page -> setOf(
            "document", "paper", "picture", "photo", "picture frame", "photo frame", "poster",
        )
        is AimSubject.Obj -> (listOf(subject.match.spokenName) + subject.match.classNames)
            .map { spokenName(it) ?: it.lowercase() }
            .toSet()
    }

    private fun iou(a: AimRect, b: AimRect): Float {
        val i = a.intersection(b) ?: return 0f
        if (i.width <= 0f || i.height <= 0f) return 0f
        val inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }
}

// MARK: - Spoken word -> detector class

object AimVocabulary {
    data class Match(
        /** What we say back: the word as the person meant it ("key"). */
        val spokenName: String,
        /** Every model class that counts as that thing. */
        val classNames: List<String>,
        val classIDs: List<Int>,
    )

    /**
     * Spoken words that the model knows under other names. Only names that
     * really exist in the vocabulary are kept at lookup time, so an entry here
     * can never invent a class ("wallet" has none today).
     */
    val synonyms: Map<String, List<String>> = mapOf(
        "wallet" to listOf("wallet", "purse"),
        "purse" to listOf("purse", "handbag"),
        "painting" to listOf("oil painting", "watercolor painting", "picture frame", "photo frame", "poster", "painting"),
        "picture" to listOf("picture frame", "photo frame", "poster", "picture", "photo"),
        "photo" to listOf("photo frame", "picture frame", "photo"),
        "photograph" to listOf("photo frame", "picture frame", "photo"),
        "phone" to listOf("phone", "smartphone", "iphone"),
        "cell phone" to listOf("phone", "smartphone", "iphone"),
        "cellphone" to listOf("phone", "smartphone", "iphone"),
        "mobile phone" to listOf("phone", "smartphone", "iphone"),
        "smartphone" to listOf("smartphone", "phone", "iphone"),
        "iphone" to listOf("iphone", "smartphone", "phone"),
        "remote" to listOf("remote", "remote control"),
        "remote control" to listOf("remote", "remote control"),
        "tv remote" to listOf("remote", "remote control"),
        "tv" to listOf("television"),
        "telly" to listOf("television"),
        "sofa" to listOf("couch"),
        "cup" to listOf("cup", "mug", "coffee cup"),
        "mug" to listOf("mug", "cup", "coffee cup"),
        "coffee mug" to listOf("mug", "coffee cup", "cup"),
        "guide dog" to listOf("dog"),
        "puppy" to listOf("puppy", "dog"),
        "kitten" to listOf("kitten", "cat"),
        "car key" to listOf("key"),
        "house key" to listOf("key"),
        "key ring" to listOf("key"),
        "keyring" to listOf("key"),
        "eyeglasses" to listOf("glasses"),
        "spectacles" to listOf("glasses"),
        "reading glasses" to listOf("glasses"),
        "bag" to listOf("bag", "handbag", "backpack"),
        // Potted plants mostly come back as houseplant or flowerpot.
        "plant" to listOf("plant", "houseplant", "flowerpot"),
        "plants" to listOf("plant", "houseplant", "flowerpot"),
        "houseplant" to listOf("houseplant", "plant", "flowerpot"),
        "potted plant" to listOf("houseplant", "plant", "flowerpot"),
        "flower" to listOf("flower", "flowerpot", "houseplant"),
        "flowers" to listOf("flower", "flowerpot", "houseplant"),
        "book" to listOf("book"),
        "books" to listOf("book", "bookcase"),
        "pills" to listOf("medicine", "pill"),
        "pill bottle" to listOf("medicine", "pill"),
        "mail" to listOf("letter", "envelope"),
        "bill" to listOf("document", "paper", "letter"),
        "page" to listOf("document", "paper"),
        "person" to listOf("person"),
        "me" to listOf("person", "face"),
        "myself" to listOf("person", "face"),
    )

    val lookAlikeTargets = listOf("dog", "cat")

    /**
     * Breed names (from AimElsewhere.collapse) that count as [animal], sorted;
     * "pet" is not a breed and is left out.
     */
    fun lookAlikes(animal: String): List<String> =
        AimElsewhere.collapse
            .filter { it.value == animal && it.key != "pet" && it.key != animal }
            .keys
            .sorted()

    private val prepositions: Set<String> = setOf(
        "to", "of", "for", "on", "in", "with", "from", "at", "by", "near", "under", "behind",
    )

    private val fillers = listOf(
        "i'm looking for ", "im looking for ", "i am looking for ", "looking for ",
        "i want ", "find my ", "find the ", "find ", "where is my ", "where's my ",
        "a picture of ", "picture of my ", "picture of ",
        "my ", "the ", "a ", "an ", "some ", "our ",
    )

    /** The vocabulary, lower-cased, with every index a name appears at. */
    fun index(classNames: List<String>): Map<String, List<Int>> {
        val out = HashMap<String, MutableList<Int>>()
        classNames.forEachIndexed { i, name ->
            out.getOrPut(name.lowercase()) { ArrayList() }.add(i)
        }
        return out
    }

    fun match(spoken: String, classNames: List<String>): Match? = match(spoken, index(classNames))

    fun match(spoken: String, index: Map<String, List<Int>>): Match? {
        val phrase = normalize(spoken)
        if (phrase.isEmpty()) return null

        val tries = ArrayList(forms(phrase))
        // When the whole phrase is unknown, look for the thing itself: the part
        // before a preposition ("keys to the car" -> "keys"), then its last word
        // ("my red keys" -> "keys"). Not simply the first word that is a class:
        // "red", "black", "house" and "car" all are.
        val words = phrase.split(" ").filter { it.isNotEmpty() }
        val head = words.takeWhile { !prepositions.contains(it) }
        if (head.isNotEmpty() && head.size < words.size) {
            tries.addAll(forms(head.joinToString(" ")))
        }
        val last = head.lastOrNull() ?: words.lastOrNull()
        if (last != null && last != phrase) tries.addAll(forms(last))

        for (word in tries) {
            val names = ArrayList<String>()
            for (candidate in (synonyms[word] ?: emptyList()) + word) {
                if (index[candidate] != null && !names.contains(candidate)) names.add(candidate)
            }
            if (names.isNotEmpty()) {
                // Look-alikes: the detector often names the breed instead of the
                // animal (a samoyed, a persian cat), so looking for a dog or a
                // cat also finds its breeds.
                for (animal in lookAlikeTargets) {
                    if (!names.contains(animal)) continue
                    for (breed in lookAlikes(animal)) {
                        if (index[breed] != null && !names.contains(breed)) names.add(breed)
                    }
                }
                val ids = names.flatMap { index[it] ?: emptyList() }
                return Match(spokenName = word, classNames = names, classIDs = ids)
            }
        }
        return null
    }

    /** The phrase itself, then singular guesses for it. */
    fun forms(phrase: String): List<String> {
        val out = ArrayList<String>()
        out.add(phrase)
        fun add(s: String) { if (s.isNotEmpty() && !out.contains(s)) out.add(s) }
        if (phrase.endsWith("ies")) add(phrase.dropLast(3) + "y")
        if (phrase.endsWith("ves")) {
            add(phrase.dropLast(3) + "f")
            add(phrase.dropLast(3) + "fe")
        }
        if (phrase.endsWith("es")) add(phrase.dropLast(2))
        if (phrase.endsWith("s") && !phrase.endsWith("ss")) add(phrase.dropLast(1))
        return out
    }

    fun normalize(spoken: String): String {
        var s = spoken.lowercase().replace('’', '\'')
        s = s.filter { it.isLetterOrDigit() || it == ' ' || it == '\'' || it == '-' }
        s = s.replace('-', ' ').trim()
        while (s.contains("  ")) s = s.replace("  ", " ")
        var changed = true
        while (changed) {
            changed = false
            for (filler in fillers) {
                if (s.startsWith(filler) && s.length > filler.length) {
                    s = s.drop(filler.length)
                    changed = true
                }
            }
        }
        return s.trim()
    }

    fun withArticle(word: String): String {
        val first = word.lowercase().firstOrNull() ?: return word
        return (if (first in "aeiou") "an " else "a ") + word
    }
}


/**
 * The things a person has already found with Something Else, most recent
 * first, so they can pick one instead of saying it again. Asked for by a Blind
 * Android Users tester (2026-09-25): a word that has found something once is
 * one the app knows. Same key and rules as the iPhone.
 */
object AimRecent {
    const val KEY = "aimRecentTargets"
    const val MAX = 6

    fun updated(list: List<String>, word: String): List<String> {
        val w = word.trim()
        if (w.isEmpty()) return list
        return (listOf(w) + list.filter { !it.equals(w, ignoreCase = true) }).take(MAX)
    }

    fun load(context: android.content.Context): List<String> =
        context.getSharedPreferences("rtcam", android.content.Context.MODE_PRIVATE)
            .getString(KEY, "")!!.split("\n").filter { it.isNotBlank() }

    fun save(context: android.content.Context, list: List<String>) {
        context.getSharedPreferences("rtcam", android.content.Context.MODE_PRIVATE)
            .edit().putString(KEY, list.joinToString("\n")).apply()
    }
}
