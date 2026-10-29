package com.mattmacosko.realtimeaicam

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.android.play.core.review.ReviewManagerFactory

/**
 * "Rate this app" (2026-10-23), the same rule as iOS RatePrompt.swift. Nothing ever asked,
 * so almost nobody rated. This uses Google Play's own in-app review card, which Play shows
 * only when its quota allows and never says whether it was shown.
 *
 * When: only after the app has actually helped. Each spoken result counts (a What's this
 * description, an answer to a question, a translation, a read page). After the 10th, the
 * next time the person comes back to the Home screen (never mid-sentence, never on a camera
 * screen) the card is requested once. After that, at most once every 120 days and only
 * after 30 more results.
 */
object RatePrompt {
    const val FIRST_ASK_AFTER = 10
    const val MORE_RESULTS_BEFORE_ASKING_AGAIN = 30
    const val DAYS_BETWEEN_ASKS = 120L

    private const val PREFS = "rtcam"
    private const val COUNT = "ratePrompt.results"
    private const val ASKED_AT = "ratePrompt.lastAskedAt"
    private const val COUNT_AT_ASK = "ratePrompt.resultsAtLastAsk"

    /** A result was given to the person. */
    fun noteResult(context: Context) {
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        p.edit().putInt(COUNT, p.getInt(COUNT, 0) + 1).apply()
    }

    /** Pure rule, unit tested. [lastAskedAtMs] is 0 when never asked. */
    fun shouldAsk(results: Int, lastAskedAtMs: Long, resultsAtLastAsk: Int, nowMs: Long): Boolean {
        if (lastAskedAtMs == 0L) return results >= FIRST_ASK_AFTER
        return nowMs - lastAskedAtMs >= DAYS_BETWEEN_ASKS * 86_400_000L &&
            results - resultsAtLastAsk >= MORE_RESULTS_BEFORE_ASKING_AGAIN
    }

    /** Call when the Home screen comes back. Waits a moment so TalkBack finishes first. */
    fun askIfDue(activity: Activity) {
        val p = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val results = p.getInt(COUNT, 0)
        val now = System.currentTimeMillis()
        if (!shouldAsk(results, p.getLong(ASKED_AT, 0L), p.getInt(COUNT_AT_ASK, 0), now)) return
        p.edit().putLong(ASKED_AT, now).putInt(COUNT_AT_ASK, results).apply()
        Handler(Looper.getMainLooper()).postDelayed({
            if (activity.isFinishing || activity.isDestroyed) return@postDelayed
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
        }, 1500)
    }
}
