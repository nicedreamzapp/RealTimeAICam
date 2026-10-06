package com.mattmacosko.realtimeaicam.aim

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log

/**
 * The two rising notes before listening and the two falling notes after, from
 * the same generated tones the iPhone uses (AimTones).
 *
 * Matt on the iPhone version: "you don't know when to speak, if you need to
 * press the button, or hold it." The beep is the answer to that, so Android
 * gets the identical one.
 *
 * Played straight from the PCM inside the generated WAV — no temp file, no
 * MediaPlayer warm-up, so the beep lands when it is meant to.
 */
object AimBeep {
    private const val TAG = "AimBeep"

    fun play(context: Context, notes: List<Double>) {
        try {
            val wav = AimTones.wav(notes)
            // Skip the 44 byte RIFF header; the rest is 16-bit mono PCM.
            val pcm = wav.copyOfRange(44, wav.size)
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(AimTones.sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(pcm.size)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
            track.write(pcm, 0, pcm.size)
            track.setNotificationMarkerPosition(pcm.size / 2)
            track.setPlaybackPositionUpdateListener(
                object : AudioTrack.OnPlaybackPositionUpdateListener {
                    override fun onMarkerReached(t: AudioTrack?) {
                        try { t?.release() } catch (_: Exception) {}
                    }

                    override fun onPeriodicNotification(t: AudioTrack?) {}
                },
            )
            track.play()
        } catch (e: Exception) {
            Log.w(TAG, "beep failed", e)
        }
    }

    @Suppress("unused")
    private fun unusedManagerHint(context: Context) {
        // Kept so the audio manager import is meaningful if a volume check is
        // ever added here; the beep deliberately does not duck speech.
        context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    }
}
