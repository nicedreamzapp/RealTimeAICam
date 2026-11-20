package com.mattmacosko.realtimeaicam

import android.app.Dialog
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.google.android.material.bottomsheet.BottomSheetBehavior.STATE_EXPANDED
import com.google.android.material.bottomsheet.BottomSheetDialog

/**
 * Rating prompt shown after enough translations. Bottom sheet style.
 */
class RatingPromptDialog : Dialog() {

    private var onDismissed: (() -> Unit)? = null

    constructor(context: android.content.Context) : super(context)

    init {
        setCanceledOnTouchOutside(false)
    }

    fun show(parent: View) {
        setContentView(buildContent())
        window?.let { w ->
            w.setBackgroundDrawableResource(android.R.color.transparent)
            val params = w.attributes
            params.width = (parent.context.resources.displayMetrics.widthPixels * 0.85).toInt()
            params.dimAmount = 0.4f
            w.attributes = params
        }
        setOnDismissListener { onDismissed?.invoke() }
        show()
    }

    fun setOnDismissed(listener: () -> Unit) {
        onDismissed = listener
    }

    private fun buildContent(): View {
        val ctx = context
        val root = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 32, 32, 32)
            background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = 24f
                setColor(android.graphics.Color.parseColor("#1c1c1e"))
            }
        }

        val title = TextView(ctx).apply {
            text = "Enjoying RealTime AI Cam?"
            textSize = 18f
            setTextColor(android.graphics.Color.WHITE)
            setPadding(0, 0, 0, 8)
            textAlignment = View.TEXT_ALIGNMENT_CENTER
        }

        val subtitle = TextView(ctx).apply {
            text = "A quick rating helps a lot — and costs nothing."
            textSize = 14f
            setTextColor(android.graphics.Color.parseColor("#aeaeb2"))
            setPadding(0, 0, 0, 24)
            textAlignment = View.TEXT_ALIGNMENT_CENTER
        }

        val buttonRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_HORIZONTAL
            setPadding(8, 0, 8, 12)

            val notNow = Button(ctx).apply {
                text = "Not now"
                setTextColor(android.graphics.Color.WHITE)
                setPadding(32, 14, 32, 14)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    setMargins(0, 0, 8, 0)
                }
                background = android.graphics.drawable.GradientDrawable().apply {
                    cornerRadius = 14f
                    setColor(android.graphics.Color.parseColor("#3a3a3c"))
                }
                setOnClickListener {
                    RatingTracker.dismissForever()
                    this@RatingPromptDialog.dismiss()
                }
            }

            val rateNow = Button(ctx).apply {
                text = "Rate now"
                setTextColor(android.graphics.Color.WHITE)
                setPadding(32, 14, 32, 14)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    setMargins(8, 0, 0, 0)
                }
                background = android.graphics.drawable.GradientDrawable().apply {
                    cornerRadius = 14f
                    setColor(android.graphics.Color.parseColor("#0a84ff"))
                }
                setOnClickListener {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(
                        "https://play.google.com/store/apps/details?id=com.mattmacosko.realtimeaicam"
                    ))
                    context.startActivity(intent)
                    this@RatingPromptDialog.dismiss()
                }
            }

            addView(notNow)
            addView(rateNow)
        }

        val noThanks = TextView(ctx).apply {
            text = "No thanks"
            textSize = 13f
            setTextColor(android.graphics.Color.parseColor("#636366"))
            setPadding(0, 4, 0, 8)
            textAlignment = View.TEXT_ALIGNMENT_CENTER
            setOnClickListener {
                RatingTracker.dismissForever()
                this@RatingPromptDialog.dismiss()
            }
        }

        root.addView(title)
        root.addView(subtitle)
        root.addView(buttonRow)
        root.addView(noThanks)

        return root
    }
}
