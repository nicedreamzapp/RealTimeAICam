package com.mattmacosko.realtimeaicam

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityManager
import com.google.android.play.core.review.ReviewManagerFactory

/**
 * "Rate this app" through Google Play's own in-app review card (Play shows it only when its
 * quota allows and never says whether it did). Same rule as iOS RatePrompt.swift.
 *
 * Rule (store brief 2026-11-04): asked ONLY right after a success moment, which here is a
 * result read aloud all the way through (a Read page, a translation, a What's this? answer,
 * a Help Me Aim description): counted when the voice finishes it, never when it errors or is
 * stopped. Not before the 3rd success, never during the first launch, at most once every 60
 * days (and 3 more successes since the last ask). No "do you like the app?" screen first.
 * Never over speech: it waits until the app's voice is done, and gives TalkBack a moment.
 */
object RatePrompt {
    const val FIRST_ASK_AFTER = 3
    const val MORE_RESULTS_BEFORE_ASKING_AGAIN = 3
    const val DAYS_BETWEEN_ASKS = 60L
    /** Launches before the first ask: never on the first one. */
    const val MIN_LAUNCHES = 2

    private const val PREFS = "rtcam"
    private const val COUNT = "ratePrompt.results"
    private const val ASKED_AT = "ratePrompt.lastAskedAt"
    private const val COUNT_AT_ASK = "ratePrompt.resultsAtLastAsk"
    private const val LAUNCHES = "ratePrompt.launches"

    /** The activity Play's card is shown over (set by MainActivity). */
    @Volatile private var activityRef: java.lang.ref.WeakReference<Activity>? = null

    /** Pure rule, unit tested. [lastAskedAtMs] is 0 when never asked. */
    fun shouldAsk(results: Int, launches: Int, lastAskedAtMs: Long, resultsAtLastAsk: Int, nowMs: Long): Boolean {
        if (launches < MIN_LAUNCHES) return false
        if (lastAskedAtMs == 0L) return results >= FIRST_ASK_AFTER
        return nowMs - lastAskedAtMs >= DAYS_BETWEEN_ASKS * 86_400_000L &&
            results - resultsAtLastAsk >= MORE_RESULTS_BEFORE_ASKING_AGAIN
    }

    /** Once per app start (MainActivity.onCreate with no saved state). */
    fun noteLaunch(activity: Activity) {
        activityRef = java.lang.ref.WeakReference(activity)
        val p = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        p.edit().putInt(LAUNCHES, p.getInt(LAUNCHES, 0) + 1).apply()
    }

    fun attach(activity: Activity) { activityRef = java.lang.ref.WeakReference(activity) }

    /**
     * A result has just been read aloud to the end (the voice's onDone). Counts it, and asks
     * right then if one is due.
     */
    fun noteResultSpoken(context: Context) {
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val results = p.getInt(COUNT, 0) + 1
        p.edit().putInt(COUNT, results).apply()
        val now = System.currentTimeMillis()
        if (!shouldAsk(results, p.getInt(LAUNCHES, 0), p.getLong(ASKED_AT, 0L), p.getInt(COUNT_AT_ASK, 0), now)) return
        val activity = activityRef?.get() ?: return
        p.edit().putLong(ASKED_AT, now).putInt(COUNT_AT_ASK, results).apply()
        Log.i("RatePrompt", "asking for a rating after success $results")
        // TalkBack reads its own focus changes after the voice ends; give it a moment.
        val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        val delay = if (am?.isTouchExplorationEnabled == true) 2_500L else 700L
        Handler(Looper.getMainLooper()).postDelayed({ launch(activity) }, delay)
    }

    private fun launch(activity: Activity) {
        if (activity.isFinishing || activity.isDestroyed) return
        try {
            val manager = ReviewManagerFactory.create(activity)
            manager.requestReviewFlow().addOnCompleteListener { request ->
                if (request.isSuccessful && !activity.isFinishing && !activity.isDestroyed) {
                    manager.launchReviewFlow(activity, request.result)
                }
            }
        } catch (t: Throwable) {
            Log.w("RatePrompt", "review flow unavailable", t)
        }
    }
}
