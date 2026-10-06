package com.mattmacosko.realtimeaicam.aim

import android.content.Context
import android.media.ExifInterface
import android.net.Uri
import android.util.Log
import com.mattmacosko.realtimeaicam.narrator.NarratorEngine
import com.mattmacosko.realtimeaicam.narrator.NarratorPrompt
import com.mattmacosko.realtimeaicam.ui.describeNeverRefusing
import com.mattmacosko.realtimeaicam.ui.looksLikeAPage
import com.mattmacosko.realtimeaicam.ui.prepareShot
import kotlinx.coroutines.runBlocking
import java.io.File

/**
 * The words that go with a Help Me Aim photo. Port of the iPhone's
 * AimCaption.swift.
 *
 * Asked for on AppleVis by the user "Matt" (2026-09-15): save the picture and
 * its description together, so the photo still says what it is when it is
 * found later or sent to someone. The What's this? model describes the kept
 * shot and the description is written INTO the saved JPEG (EXIF
 * ImageDescription and UserComment). Nothing is uploaded.
 */
object AimCaption {
    private const val TAG = "AimCaption"

    /** Blocking. The description, or null when the model had nothing to say. */
    fun describe(context: Context, engine: NarratorEngine, jpeg: ByteArray, isPage: Boolean): String? = try {
        val raw = File(context.cacheDir, "help-me-aim-raw.jpg").apply { writeBytes(jpeg) }
        val shot = File(context.cacheDir, "help-me-aim.jpg")
        if (prepareShot(raw, shot) == null) {
            null
        } else {
            // A page with words on it gets the mail reader, anything else the
            // scene describer: the same split as What's this?.
            val page = isPage && runBlocking { looksLikeAPage(context, shot) }
            val question = if (page) NarratorPrompt.PAGE_QUESTION else NarratorPrompt.SCENE_QUESTION
            describeNeverRefusing(context, shot, question, page, engine).trim().ifBlank { null }
        }
    } catch (t: Throwable) {
        Log.e(TAG, "describe failed", t)
        null
    }

    /**
     * Blocking. Saves a JPEG already on disk to Pictures/RealTime AI Cam with
     * [caption] written into it. What's this?'s Save Photo button (asked for by
     * a Blind Android Users tester, 2026-09-25) uses the same folder and the
     * same caption fields as Help Me Aim.
     */
    fun saveWithCaption(context: Context, jpeg: File, caption: String): Uri? = try {
        val values = android.content.ContentValues().apply {
            put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "RTCam-${System.currentTimeMillis()}.jpg")
            put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RealTime AI Cam")
            }
        }
        val uri = context.contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        if (uri != null) {
            context.contentResolver.openOutputStream(uri)?.use { out -> jpeg.inputStream().use { it.copyTo(out) } }
            if (caption.isNotBlank()) embed(context, uri, caption)
        }
        uri
    } catch (t: Throwable) {
        Log.e(TAG, "save failed", t)
        null
    }

    /** Blocking. Writes the caption into the photo this app just saved. */
    fun embed(context: Context, uri: Uri, caption: String): Boolean = try {
        context.contentResolver.openFileDescriptor(uri, "rw")?.use { pfd ->
            val exif = ExifInterface(pfd.fileDescriptor)
            exif.setAttribute(ExifInterface.TAG_IMAGE_DESCRIPTION, caption)
            exif.setAttribute(ExifInterface.TAG_USER_COMMENT, caption)
            exif.saveAttributes()
            true
        } ?: false
    } catch (t: Throwable) {
        Log.e(TAG, "could not write the caption", t)
        false
    }
}
