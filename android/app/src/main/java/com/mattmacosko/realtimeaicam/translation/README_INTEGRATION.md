# Spanish Translation Engine — Integration Notes

Kotlin port of the iOS `FixedSpanishEngine` (project 601). Fully offline, no new gradle
dependencies (uses `android.util.JsonReader`, `java.util.zip.GZIPInputStream`,
`java.util.regex` only).

## Files

- `SpanishTranslationEngine.kt` (this package: `com.mattmacosko.realtimeaicam.translation`)
- Data: `app/src/main/assets/es_final_with_rules.json.gz` (~4.2 MB gz, ~27 MB decompressed,
  268,631 dictionary entries). Already in place.

## How to instantiate

Loading parses a 27 MB JSON stream and takes a few seconds — **do it once, on a background
thread**, and keep a single instance alive (e.g. in the Application class or a ViewModel).

```kotlin
import com.mattmacosko.realtimeaicam.translation.SpanishTranslationEngine

val engine = SpanishTranslationEngine()

// Background thread (coroutine shown; a plain Thread works too):
scope.launch(Dispatchers.IO) {
    val ok = engine.load(context.assets.open("es_final_with_rules.json.gz"))
    // ok == true on success; engine.isLoaded flips true
}
```

## API

- `fun load(input: InputStream, gzipped: Boolean = true): Boolean` — blocking load.
- `fun translate(text: String): String` — Spanish -> English. Thread-safe. Returns the
  input unchanged if the engine is not loaded yet or text is empty (safe to call early).
- `val isLoaded: Boolean` / `fun isReady(): Boolean` — true once data is loaded.
- `val entryCount: Int` — loaded dictionary entries (expect **268,631**; use to sanity-check).
- `companion fun SpanishTranslationEngine.Companion.load(input)` — construct+load in one call.

Results are internally cached (last 500 unique strings), so re-translating the same OCR
frame text is free.

## Smoke-test pairs (hand-traced against the iOS engine's logic)

After wiring, feed these through `translate()` and expect EXACTLY these outputs:

| Input                            | Expected output                    |
|----------------------------------|------------------------------------|
| `El menú del día`                | `The menu of the day`              |
| `El gato negro come arroz`       | `The black cat eat rice`           |
| `Se vende pan`                   | `For sale bread`                   |
| `¿Dónde está el baño?`           | `Where is the bathroom?`           |
| `Por la mañana quiero un café`   | `In the morning want to a coffee`  |

Notes on the expected quirks (identical on iOS — this is a dictionary+rules engine, not an
NMT model): "eat" is not conjugated, "Se vende pan" keeps phrase-first order, and unknown
words pass through untranslated. Casing is normalized: everything is lowercased during
translation and sentence starts are re-capitalized at the end.

## Testing caveat

`android.util.JsonReader` is an Android class, so pure-JVM unit tests need Robolectric;
otherwise verify on device/emulator (entryCount == 268631, then the 5 pairs above).
