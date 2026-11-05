package com.mattmacosko.realtimeaicam

import android.content.Context
import android.content.ContextWrapper
import android.content.res.Configuration
import android.content.res.Resources
import androidx.annotation.StringRes
import com.mattmacosko.realtimeaicam.translation.YourLanguage
import com.mattmacosko.realtimeaicam.translation.YourLanguageRules
import java.util.Locale

/**
 * The language of the app's own words: buttons, menus, dialogs, TalkBack labels, the guide and
 * every line the app itself speaks (2026-11-05, for a blind Spanish speaker).
 *
 * Spanish when the phone (or the app's own language in Android settings) is Spanish, OR when
 * "Your language" is Spanish; English otherwise. The Spanish ships in the app (values-es), so
 * unlike Your language's translator nothing downloads. Mirrors iOS AppLang.swift.
 *
 * Compose screens get it through [localized] (MainActivity wraps the whole UI), so
 * stringResource() is already in the right language. Code without a Compose context
 * (the announcer, Help Me Aim, the rules objects) uses [str].
 */
object AppLang {
    const val ENGLISH = "en"
    const val SPANISH = "es"

    @Volatile private var app: Context? = null

    /** Called once from [RTCamApp.onCreate], before anything can ask for a string. */
    fun init(context: Context) {
        app = context.applicationContext
    }

    /** The rule, pure for tests: the phone's (or per-app) language first, then Your language. */
    fun uiCode(appLanguage: String?, yourLanguage: String): String {
        if (appLanguage != null && YourLanguageRules.normalize(appLanguage) == SPANISH) return SPANISH
        return if (yourLanguage == SPANISH) SPANISH else ENGLISH
    }

    /** Unit tests (no Android) set this to try the Spanish rules. */
    @Volatile var testCode: String? = null

    /** "es" or "en". Safe from any thread. */
    fun code(): String {
        testCode?.let { return it }
        val c = app ?: return ENGLISH
        // The application's own configuration carries Android 13's per-app language too.
        val appLanguage = c.resources.configuration.locales.get(0)?.language
        return uiCode(appLanguage, YourLanguage.code(c))
    }

    val isSpanish: Boolean get() = code() == SPANISH

    fun locale(): Locale = Locale.forLanguageTag(code())

    private val cache = HashMap<String, Resources>()

    /** Resources in the app's language (from [context]'s configuration; the app's by default). */
    fun resources(context: Context? = app): Resources {
        val base = context ?: error("AppLang.init was not called")
        val c = code()
        val baseConfig = base.resources.configuration
        // Keyed on the base configuration too: a turn or a font-size change gets fresh resources.
        val key = "$c|${baseConfig.hashCode()}|${System.identityHashCode(base)}"
        synchronized(cache) {
            cache[key]?.let { return it }
            val config = Configuration(baseConfig).apply { setLocale(Locale.forLanguageTag(c)) }
            val res = base.createConfigurationContext(config).resources
            if (cache.size > 8) cache.clear()
            cache[key] = res
            return res
        }
    }

    /** One of the app's strings in the app's language. */
    fun str(@StringRes id: Int, vararg args: Any): String {
        if (app == null) return TestStrings.get(id, testCode ?: ENGLISH, args)
        val r = resources()
        return if (args.isEmpty()) r.getString(id) else r.getString(id, *args)
    }

    /** A quantity string ("1 second" / "2 seconds") in the app's language. */
    fun plural(id: Int, count: Int, vararg args: Any): String {
        if (app == null) return TestStrings.plural(id, count, testCode ?: ENGLISH, args)
        return resources().getQuantityString(id, count, *args)
    }

    /**
     * [base] (the activity) with its resources in the app's language, for Compose's LocalContext.
     * Still the activity underneath, so starting activities and system services work as before.
     */
    fun localized(base: Context): Context {
        val res = resources(base)
        if (res.configuration.locales.get(0) == base.resources.configuration.locales.get(0)) return base
        return object : ContextWrapper(base) {
            override fun getResources(): Resources = res
        }
    }

    /** Clears cached resources. */
    fun reset() = synchronized(cache) { cache.clear() }
}

/**
 * JVM unit tests have no Android resources: strings come straight from res/values*.xml in the
 * source tree, looked up by the R field's name. Never used in the app (init runs first).
 */
internal object TestStrings {
    private val tables = HashMap<String, Map<String, String>>()
    private val plurals = HashMap<String, Map<String, Map<String, String>>>()

    private fun dir(lang: String) = if (lang == AppLang.ENGLISH) "values" else "values-$lang"

    private fun files(lang: String): List<java.io.File> {
        val roots = listOf("src/main/res", "app/src/main/res", "android/app/src/main/res")
        val d = roots.map { java.io.File(it, dir(lang)) }.firstOrNull { it.isDirectory } ?: return emptyList()
        return d.listFiles { f -> f.name.startsWith("strings") && f.name.endsWith(".xml") }?.toList().orEmpty()
    }

    private fun unescape(s: String) = s.trim().removeSurrounding("\"")
        .replace("\\'", "'").replace("\\\"", "\"").replace("\\n", "\n").replace("\\@", "@").replace("\\?", "?")
        .replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")

    private fun table(lang: String): Map<String, String> = synchronized(tables) {
        tables.getOrPut(lang) {
            val out = HashMap<String, String>()
            val re = Regex("""<string\s+name="([^"]+)"[^>]*>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
            files(lang).forEach { f -> re.findAll(f.readText()).forEach { out[it.groupValues[1]] = unescape(it.groupValues[2]) } }
            out
        }
    }

    private fun pluralTable(lang: String): Map<String, Map<String, String>> = synchronized(plurals) {
        plurals.getOrPut(lang) {
            val out = HashMap<String, Map<String, String>>()
            val block = Regex("""<plurals\s+name="([^"]+)"[^>]*>(.*?)</plurals>""", RegexOption.DOT_MATCHES_ALL)
            val item = Regex("""<item\s+quantity="([^"]+)"\s*>(.*?)</item>""", RegexOption.DOT_MATCHES_ALL)
            files(lang).forEach { f ->
                block.findAll(f.readText()).forEach { b ->
                    out[b.groupValues[1]] = item.findAll(b.groupValues[2]).associate { it.groupValues[1] to unescape(it.groupValues[2]) }
                }
            }
            out
        }
    }

    private fun name(id: Int, kind: String): String? = try {
        Class.forName("com.mattmacosko.realtimeaicam.R\$$kind").fields.firstOrNull { it.getInt(null) == id }?.name
    } catch (_: Throwable) { null }

    fun get(id: Int, lang: String, args: Array<out Any>): String {
        val n = name(id, "string") ?: return ""
        val raw = table(lang)[n] ?: table(AppLang.ENGLISH)[n] ?: return ""
        return if (args.isEmpty()) raw else String.format(Locale.forLanguageTag(lang), raw, *args)
    }

    fun plural(id: Int, count: Int, lang: String, args: Array<out Any>): String {
        val n = name(id, "plurals") ?: return ""
        val forms = pluralTable(lang)[n] ?: pluralTable(AppLang.ENGLISH)[n] ?: return ""
        val raw = (if (count == 1) forms["one"] else forms["other"]) ?: forms["other"] ?: return ""
        return String.format(Locale.forLanguageTag(lang), raw, *args)
    }
}
