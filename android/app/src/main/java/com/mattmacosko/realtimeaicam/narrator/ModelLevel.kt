package com.mattmacosko.realtimeaicam.narrator

import android.app.ActivityManager
import android.content.Context
import java.io.File

/**
 * The four sizes of What's this?, smartest first (1.24, same as iPhone 1.4.0).
 *
 * Blind scores are the living benchmark's (27 public photos, three judges):
 * github.com/nicedreamzapp/RealTimeAICam/tree/main/benchmarks. Balanced ships in
 * the install-time asset pack so the first photo works offline; the other three
 * download once from our own server and are then just as offline.
 */
enum class ModelLevel(
    val title: String,
    val score: Int,
    val blurb: String,
    val modelFile: String,
    val mmprojFile: String,
    val bytes: Long,
    /**
     * Time for one answer compared with Balanced on a phone CPU. Quick is the
     * Cricket's measured ratio in this build (warm, 768 px scene: 97 s vs Balanced
     * 135 s, 2026-10-30).
     * Clear and Sharp are estimates from how llama.cpp's quant types run on a
     * CPU (speed-grid.md), not timed on a phone yet; real answers correct them.
     */
    val costVsBalanced: Double,
    /** Total RAM (ActivityManager.totalMem) before the level is offered. */
    val minimumMemory: Long,
) {
    SHARP("Sharp", 78, "Most accurate. LFM3-Omni-2B by Liquid AI, full detail.",
        "lfm3-omni-2b-Q8_0.gguf", "lfm3-omni-2b-mmproj-vision-Q8_0.gguf",
        2_049_283_586L, 1.3, 7_000_000_000L),
    CLEAR("Clear", 75, "Nearly as accurate as Sharp at half the size.",
        "lfm3-omni-2b-Q3_K_M.gguf", "lfm3-omni-2b-mmproj-vision-Q8_0.gguf",
        1_117_944_898L, 1.05, 3_500_000_000L),
    BALANCED("Balanced", 57, "Built into the app.",
        NarratorEngine.MODEL_FILE, NarratorEngine.MMPROJ_FILE,
        735_090_426L, 1.0, 0L),
    QUICK("Quick", 47, "Fastest, for older phones. The model RT Cam used before 1.23.",
        "vision-narrator-0.8b-Q4_K_M.gguf", "vision-narrator-0.8b-mmproj-F16.gguf",
        736_644_128L, 0.72, 0L);

    val key: String get() = name.lowercase()
    val isBundled: Boolean get() = this == BALANCED
    val usesLfm3Prompt: Boolean get() = this != QUICK
    /** Folder on our server. */
    val remoteBase: String get() = "https://ineedhemp.com/models/rtcam/$key/"

    fun sizeText(): String =
        if (bytes >= 1_000_000_000L) String.format("%.2f GB", bytes / 1e9)
        else String.format("%.0f MB", bytes / 1e6)

    fun fitsThisPhone(context: Context): Boolean {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        return info.totalMem >= minimumMemory
    }

    /** Where a downloaded level lives: filesDir/models/<level>. */
    fun folder(context: Context): File = File(context.filesDir, "models/$key")
    fun staging(context: Context): File = File(context.filesDir, "models/$key.partial")

    fun isInstalled(context: Context): Boolean {
        if (isBundled) return NarratorEngine.get(context).hasModel()
        val dir = folder(context)
        val manifest = File(dir, "manifest.json")
        if (!manifest.isFile) return false
        return ModelDownloader.readManifest(manifest)?.files?.all { File(dir, it.name).length() == it.size } == true
    }

    companion object {
        fun fromKey(key: String?): ModelLevel? = entries.firstOrNull { it.key == key }
    }
}

/** What kind of photo is being answered: the page reader or a scene. */
enum class PhotoKind { PAGE, SCENE }

/** Settings > Models: "Accuracy first" (default) or "Speed first". */
enum class ModelPriority(val title: String) {
    ACCURACY("Accuracy first"), SPEED("Speed first");

    /**
     * The longest a level may take and still be picked automatically. Matt's rule
     * (2026-10-30): mail, money and medicine get the most accurate level the phone
     * can run in about a minute; a scene gets the smartest within about 20 s.
     */
    fun budget(kind: PhotoKind): Double = when (this) {
        ACCURACY -> if (kind == PhotoKind.PAGE) 60.0 else 20.0
        SPEED -> if (kind == PhotoKind.PAGE) 20.0 else 10.0
    }
}

/** Picks a level for each photo, from this phone's measured speed and what is on it. */
object ModelPicker {
    private const val PREFS = "model_picker"
    const val CHOICE = "choice"              // "auto" or a level key
    const val PRIORITY = "priority"
    const val BALANCED_SECONDS = "balanced_seconds"

    /** A page is read at 1024 px, a scene at 768 px. */
    const val PAGE_COST = 1.4

    fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun manualLevel(context: Context): ModelLevel? = ModelLevel.fromKey(prefs(context).getString(CHOICE, "auto"))
    fun setManualLevel(context: Context, level: ModelLevel?) =
        prefs(context).edit().putString(CHOICE, level?.key ?: "auto").apply()

    fun priority(context: Context): ModelPriority =
        ModelPriority.entries.firstOrNull { it.name == prefs(context).getString(PRIORITY, null) } ?: ModelPriority.ACCURACY
    fun setPriority(context: Context, p: ModelPriority) = prefs(context).edit().putString(PRIORITY, p.name).apply()

    /**
     * Seconds for one scene answer on Balanced on this phone. On Android the first
     * real answer is the speed check (a separate check would cost a budget phone
     * three minutes of CPU at launch); Settings can also run one on purpose.
     */
    fun balancedSeconds(context: Context): Double? =
        prefs(context).getFloat(BALANCED_SECONDS, 0f).toDouble().takeIf { it > 0 }

    fun setBalancedSeconds(context: Context, s: Double) =
        prefs(context).edit().putFloat(BALANCED_SECONDS, s.toFloat()).apply()

    /** Folds one real answer into the estimate (the first one sets it). */
    fun noteAnswer(context: Context, level: ModelLevel, kind: PhotoKind, seconds: Double) {
        if (seconds <= 0) return
        val asBalanced = seconds / level.costVsBalanced / (if (kind == PhotoKind.PAGE) PAGE_COST else 1.0)
        val current = balancedSeconds(context)
        setBalancedSeconds(context, if (current == null) asBalanced else current * 0.8 + asBalanced * 0.2)
    }

    fun estimate(context: Context, level: ModelLevel, kind: PhotoKind): Double? =
        balancedSeconds(context)?.let { it * level.costVsBalanced * (if (kind == PhotoKind.PAGE) PAGE_COST else 1.0) }

    fun candidates(context: Context): List<ModelLevel> = ModelLevel.entries.filter { it.fitsThisPhone(context) }

    /** The smartest level within the budget, on the phone or not; the fastest when none fit. */
    fun ideal(context: Context, kind: PhotoKind, priority: ModelPriority = priority(context)): ModelLevel {
        if (balancedSeconds(context) == null) return ModelLevel.BALANCED
        val budget = priority.budget(kind)
        val c = candidates(context)
        return c.firstOrNull { (estimate(context, it, kind) ?: Double.MAX_VALUE) <= budget } ?: c.last()
    }

    /** What automatic mode wants downloaded. */
    fun wanted(context: Context): Set<ModelLevel> =
        if (balancedSeconds(context) == null || manualLevel(context) != null) emptySet()
        else setOf(ideal(context, PhotoKind.PAGE), ideal(context, PhotoKind.SCENE))

    /** The level to run right now, from what is actually on the phone. */
    fun level(context: Context, kind: PhotoKind): ModelLevel {
        val installed = ModelLevel.entries.filter { it.isInstalled(context) }
        manualLevel(context)?.let { return if (it in installed) it else ModelLevel.BALANCED }
        val ideal = ideal(context, kind)
        if (ideal in installed) return ideal
        val budget = priority(context).budget(kind)
        val ready = candidates(context).filter { it in installed }
        return ready.firstOrNull { (estimate(context, it, kind) ?: Double.MAX_VALUE) <= budget }
            ?: ready.lastOrNull() ?: ModelLevel.BALANCED
    }

    fun spoken(seconds: Double?): String = when {
        seconds == null -> "speed not measured yet"
        seconds < 1.5 -> "about 1 second"
        seconds < 60 -> "about ${Math.round(seconds)} seconds"
        else -> Math.round(seconds / 60).let { if (it == 1L) "about a minute" else "about $it minutes" }
    }
}
