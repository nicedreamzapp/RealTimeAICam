package com.mattmacosko.realtimeaicam

import com.google.android.play.core.splitcompat.SplitCompatApplication

/** The app object: only here so the app's language (AppLang) is known before any screen or voice starts. */
class RTCamApp : SplitCompatApplication() {
    override fun onCreate() {
        super.onCreate()
        AppLang.init(this)
    }
}
