package com.mattmacosko.realtimeaicam.readers

import android.graphics.Bitmap
import android.util.Log
import com.googlecode.tesseract.android.TessBaseAPI
import com.mattmacosko.realtimeaicam.camera.PageReader
import com.mattmacosko.realtimeaicam.camera.PageReaderFactory

/**
 * Tesseract for the scripts ML Kit cannot read (Russian, Ukrainian, Thai, Arabic). Loaded by
 * name from ScriptReaders once this module is installed; nothing in the base app links to it.
 */
class TessPageReaderFactory : PageReaderFactory {
    override fun open(dataDir: String, lang: String): PageReader {
        val api = TessBaseAPI()
        if (!api.init(dataDir, lang, TessBaseAPI.OEM_LSTM_ONLY)) {
            api.recycle()
            throw IllegalStateException("Tesseract could not load $lang from $dataDir")
        }
        api.pageSegMode = TessBaseAPI.PageSegMode.PSM_AUTO
        return TessPageReader(api)
    }
}

private class TessPageReader(private val api: TessBaseAPI) : PageReader {
    override fun read(bitmap: Bitmap): String {
        api.setImage(bitmap)
        val text = api.utF8Text.orEmpty()
        val confidence = api.meanConfidence()
        api.clear()
        // A frame with no real text still comes back as a few stray marks; drop those.
        if (confidence < MIN_CONFIDENCE) {
            Log.d("TessPageReader", "dropped low-confidence read ($confidence)")
            return ""
        }
        // Tesseract's output is in reading order (right to left for Arabic) with blank lines
        // between blocks; keep the lines, drop the empties.
        return text.lines().map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n")
    }

    override fun close() = api.recycle()

    private companion object { const val MIN_CONFIDENCE = 45 }
}
