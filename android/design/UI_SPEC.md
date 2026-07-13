# RealTime AI Camera — Android Compose UI Replication Spec

**Goal: pixel-faithful port of the iOS app.** This spec is derived line-by-line from the iOS SwiftUI source (`/Users/matthewmacosko/Documents/project 601/`) and verified against real App Store screenshots in `design/appstore-screenshots/`. Numbers are in iOS points; treat **1 pt = 1 dp** everywhere. Where a screenshot disagrees with this spec, THE SPEC (current source code) WINS — several store screenshots show an older build (plain-text "Objects: 19 / FPS: 30.1" instead of the current chip-style readouts).

**Assets in this folder:**
- `design/app-icon-1024.png` — the 1024×1024 app icon source (copied from `Assets.xcassets/AppIcon.appiconset/iconblack.png`). Use for all Android launcher icon densities (adaptive icon: use the full image as foreground on its own black background, or legacy full-bleed).
- `design/splash-background.png` — the Home screen background image (518×778 source, "liquid glass" blue water-droplet artwork with embossed Apple/gear/car shapes). Rendered full-bleed with `ContentScale.Crop`.
- `design/appstore-screenshots/01…07` — 7 real screenshots (home, OCR landscape, Spanish OCR menu translation, object detection portrait, LiDAR detection, OCR, iPad).

---

## 0. Global rules

| Item | iOS behavior | Compose equivalent |
|---|---|---|
| Color scheme | `preferredColorScheme(.dark)` forced app-wide | Force dark theme; never follow system light mode |
| Status bar | `statusBarHidden(true)` | `WindowInsetsController.hide(statusBars)`; draw edge-to-edge (`enableEdgeToEdge`, hide status bar, allow content behind cutout) |
| Baseline scaling | All Home-screen sizes multiply by `scale = min(screenWidthDp / 390, 1.0)` (390 = iPhone 14 Pro width) | Compute the same `scale` from `LocalConfiguration.screenWidthDp` |
| Font | SF Pro (default), SF Pro Rounded (`design: .rounded`), SF Mono (`design: .monospaced`) | Roboto for default; **Nunito Sans or Roboto with 0 tracking** for "rounded" numerics (closest free match; Roboto Medium acceptable); Roboto Mono for monospaced |
| iOS text styles used | largeTitle=34, title2=22, title3=20, headline=17 semibold, body=17, subheadline=15, footnote=13, caption=12 medium, caption2=11 | Use these exact sp values, not Material defaults |
| `.ultraThinMaterial` ("liquid glass") | Blurred translucent panel; in forced-dark mode reads as a dark smoky glass | Compose: `Color(0xFF1E1E1E)` at the composite alpha given per-element **plus** `Modifier.blur`-style backdrop blur via `RenderEffect` on Android 12+; below 12, plain translucent surface `#262626` at the stated opacity. When source says `.ultraThinMaterial.opacity(X)` layered over `Color.black.opacity(0.25)`, implement as a single circle/rect of `Color.Black.copy(alpha = 0.25f + 0.15f*X)` ≈ values given per element below |
| iOS system colors (dark-mode values — app is always dark) | blue `#0A84FF`, green `#30D158`, orange `#FF9F0A`, red `#FF453A`, yellow `#FFD60A`, purple `#BF5AF2`, cyan `#64D2FF`, gray `#8E8E93`, `.primary`=white, `.secondary`=`#EBEBF5` @ 60% (≈`#99EBEBF5`) | Define these as constants; do NOT use Material color roles |
| Haptics | `UIImpactFeedbackGenerator(.light)` on back/text-tap; `UINotificationFeedbackGenerator(.success)` on copy/translate success | `performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)` for light impact; `CONFIRM` for success |
| Emoji | Real emoji characters are UI elements (📖 🗣️ 🇲🇽 🇺🇸 🌎 🐶 💡 👩 👨 🧑) | Render as text with system emoji font. Note: Noto emoji ≠ Apple emoji; if exactness matters most on the three home buttons, ship Apple-style emoji PNGs as drawables (acceptable difference otherwise) |

### Navigation structure
Single-activity, single "mode" state machine — **no tabs, no nav bar, no gestures for navigation**:

```
AppMode: home | objectDetection | ocrEnglish | ocrSpanish
```

- **Launch → Home** always (even after process restore; iOS explicitly resets to `.home` on cold start and on backgrounding).
- Home → the 3 camera modes via the 3 big capsule buttons.
- Every camera mode → Home via a "‹ Back" pill button (top-left). System back gesture should do the same.
- **Instructions sheet** presented modally over Home: automatically on very first launch (persist `hasShownInstructions` boolean), and any time via the "INFO 💡 GUIDE" button.
- **Settings overlay** is an in-screen dialog available only inside the two OCR modes (gear button).
- Mode transitions are instant (no slide animation between modes); overlays/popups animate (specified per-element).
- All mode switches are debounced: ignore a second tap on any debounced button within ~0.5 s, and ignore Back re-entry within 1.0 s.

---

## 1. Home screen (`HomeView` + `HeadingView` + `AnimatedVoicePicker`)

See screenshot `01_screenshot_2025-09-02.png` — this one matches current code exactly.

### 1.1 Background
- `splash-background.png` full-bleed, `ContentScale.Crop`, ignores all insets.

### 1.2 Vertical layout (top → bottom)
```
Column (fills screen, horizontal padding 16dp):
  Spacer(min 80dp, weight)          // top gap
  HeadingView                        // fixed height 120dp block
  Spacer (weight)
  Column(spacing 18dp) of 3 buttons  // inside a 220dp-tall slot, centered
  Spacer (weight)
  VoicePicker
  Spacer(min 25dp)
  Spacer(min 50dp)                   // extra bottom gap
```
- Version label: bottom-left corner, text `v1.0.8 (11)` style — `caption2` 11sp, color = iOS `.secondary` (`#EBEBF5` @ 60%), padding start 14dp, bottom 10dp, non-interactive.
- INFO/GUIDE button: overlay top-end, padding top 8dp, end 16dp (see 1.5).

### 1.3 HeadingView — the big "RealTime / Ai Camera" pill
Container: width = 92% of screen width, height 120dp, horizontally centered, its center at y=60dp of its 120dp slot. `scaleFactor = min(width/390, 1)` — all values below × scaleFactor.

Layered capsule (fully rounded pill), bottom to top:
1. **Glow**: capsule filled `#0A84FF` @ 35%, blur radius 18dp, scaled 1.12× of the pill.
2. **Main fill**: horizontal linear gradient, left→right: `white @ 82%` → `#0A84FF @ 55%` → `white @ 82%`.
3. **Top gloss**: capsule, vertical gradient `white @ 62%` → transparent, blur 1.9dp, inset 3dp from top.
4. **Outer stroke**: `rgb(0.20, 0.43, 0.82)` = `#3370D1` @ 42%, width 4.2dp.
5. **Inner stroke**: black @ 16%, width 1.9dp, inset 1.9dp.
6. **Inner glow**: capsule fill white @ 18%, blur 5.5dp, inset 8dp.
7. **Text** (content padding: horizontal 25dp, vertical 14dp): two lines, line spacing −8dp (overlap):
   - "RealTime" — 52sp, bold, **outlined text**: fill `#A3D9FF` (rgb 0.64,0.85,1.0), black outline (see 1.6) stroke width 2.1.
   - "Ai Camera" — 44sp, bold, fill `#CFEDFF` (rgb 0.81,0.93,1.0), same outline.

### 1.4 The three mode buttons (identical construction, different accent + content)
All values × `scale`. Shape: capsule (fully rounded). Width: `min(340*scale, screenWidth − 36)`, content vertical padding 16dp, extra horizontal padding 8dp. Content is horizontally centered.

Layered background (bottom → top), where **A** = accent color:
1. Capsule fill: vertical gradient `white @ 23%` (top) → `A @ 50%` (bottom).
2. Gloss stripe: capsule fill `white @ 13%`, height 24dp, offset y −18dp (sits near top edge).
3. Stroke: `white @ 80%`, width 4.8dp.
4. Stroke: `A @ 100%`, width 2.4dp (inside the white stroke visually).
5. Inner bottom shade: capsule fill `black @ 12%`, blur 7dp, offset y +16dp.
6. Clip everything to the capsule.
Drop shadows (outside): `black @ 38%`, radius 15dp, dy 5dp **and** a colored glow `A @ 50%`, radius 12dp, no offset.

| Button | Accent A | Content (HStack, spacing shown) |
|---|---|---|
| 1. English OCR | iOS blue `#0A84FF` | spacing 4: "📖" 34sp · OutlinedText "Eng Text2Speech" 20sp · ShadedEmoji "🗣️" 29 |
| 2. Spanish OCR | iOS green `#30D158` | spacing 2: "🇲🇽" 31sp · "Span" 18sp · "🇺🇸" 31sp · "Eng" 18sp · "🌎" 31sp · "Translate" 18sp (all words OutlinedText) |
| 3. Object Detection | iOS orange `#FF9F0A` | spacing 4: "🐶" 35sp · OutlinedText "Object Detection" 20sp |

**ShadedEmoji**: white circle `white @ 92%`, diameter = 1.35 × emoji size (≈39dp), shadow black @ 9% radius 3 dy 2; emoji centered on it at given size.

### 1.5 INFO 💡 GUIDE button (top-right)
Content: HStack spacing 6: OutlinedText "INFO" 14sp · "💡" 14sp · OutlinedText "GUIDE" 14sp. Padding: vertical 6dp, horizontal 18dp. Background = same 5-layer capsule recipe as mode buttons but with accent = **black** (gradient white 23% → black 50%; strokes white 80% @ 4.8 and black @ 2.4; gloss & inner shade identical, NOT scaled — fixed dp). Shadow black @ 38% r12 dy5. Opens the Instructions sheet.

### 1.6 OutlinedText component (used everywhere above)
Bold text drawn 5 times: 4 copies in the stroke color (default black) offset (±w, ±w) where w = strokeWidth (default 1.1dp; heading uses 2.1), plus the fill-color copy on top. In Compose: either draw 4 offset Text clones in a Box, or use `TextStyle(drawStyle = Stroke(width*2))` underlay + fill overlay. Default fill = white.

### 1.7 Voice picker (collapsed pill)
- HStack spacing 6: gender emoji (👩/👨/🧑) 28sp · voice name + quality tag, e.g. "Samantha (Enhanced)" — 20sp bold white · chevron icon 14sp bold white (up when closed, down when open → Material `KeyboardArrowUp/Down`).
- Padding horizontal 12dp, vertical 6dp. Background: capsule fill iOS purple `#BF5AF2` @ 24%; stroke black width 1.1dp.
- Appears with the same fade+scale entry animation as buttons.

### 1.8 Voice grid popup (tapping picker)
- Anchored above picker, offset y −200dp; full-screen invisible scrim to dismiss on outside tap.
- Panel: width 280dp, padding 8dp, RoundedRect corner 12dp, fill black @ 85%, stroke purple `#BF5AF2` @ 40% width 1dp, shadow black @ 50% radius 10.
- 2-column grid, spacing 8dp, up to 10 voices. Cell: VStack spacing 4 — gender emoji 20sp, name 11sp medium white; vertical padding 6dp; RoundedRect corner 8: fill purple @ 50% if selected else black @ 60%.
- Transition: scale from 0.9 + fade, spring ~300ms. Selecting a voice closes the grid and speaks a welcome line.

### 1.9 Entry animation (first appearance only per process)
Each element fades 0→1 **and** scales 0.7→1, easeOut 300ms, triggered on a stagger: heading at 0.20s, button1 at 0.70s, button2 at 1.20s, button3 at 1.70s, voice picker at 2.20s after screen appear. On subsequent visits to Home everything is shown immediately.

---

## 2. Object Detection screen (`ObjectDetectionView`)

Full-screen camera preview (CameraX `PreviewView` inside Compose) with pinch-to-zoom. See screenshot `05_LiDAR.png` for overall layout (note: chips at top are the OLD style in that shot; use the chip specs below).

### 2.1 Top row (portrait)
Padding: top = safeTop + 50dp; leading = max(safeLeading+16, 28)dp; trailing = max(safeTrailing+28, 36)dp.

- **Back button** (left): HStack spacing 6 — chevron-left icon 16sp bold white (Material `ArrowBackIosNew` sized 16) + "Back" 16sp bold white. Padding v10 h16. Background RoundedRect corner 20dp, ultraThinMaterial @ 85% → Compose `#262626 @ ~72%` + backdrop blur.
- **FPS chip** (right, top-aligned with Back): HStack spacing 6 — speedometer icon (Material `Speed`) 12sp medium tinted `fpsColor` · fps value `"%.2f"` 14sp **bold rounded** white · "FPS" 11sp medium white @ 80%. Padding v8 h5. Background RoundedRect corner 12dp, material @ 55% (`#262626 @ ~55%`), stroke `fpsColor` width 1.25dp.
  - fpsColor: `<15` red `#FF453A` · `15–25` orange `#FF9F0A` · `25–30` yellow `#FFD60A` · `≥30` green `#30D158`.
- **Object-count chip** (below FPS, right-aligned, only when count > 0): eye icon 12sp tinted `countColor` · count 14sp bold rounded white. Padding v8 h12, RoundedRect corner 12, material @ 85%, stroke `countColor` width 1.5dp.
  - countColor: 0 gray · 1–3 blue `#0A84FF` · 4–6 orange · 7–10 red · >10 purple `#BF5AF2`.

(Landscape uses `PerformanceOverlayView`: same two chips side-by-side spacing 10, but chip background is solid `black @ 80%` with an extra faint white inner stroke (white @10%, 0.5dp, blurred 0.5) and two shadows: `color @ 30% r4 dy2` + `black @ 50% r8 dy4`; the whole cluster rotated 90° and pinned near the top-right edge.)

### 2.2 Zoom indicator
When zoom < 0.95× or > 1.05×: pill at top-center, top padding safeTop + 60dp. Text `"%.1fx"` 18sp medium **rounded** white; padding h12 v6; capsule fill black @ 70%. Fade in/out 200ms.

### 2.3 LiDAR notification toast
Centered vertically (vertical center of screen), shown ~2s on LiDAR toggle/etc. HStack: ruler icon 16sp + message 15sp medium, white. Padding h20 v12. Background: RoundedRect corner 20, ultraThinMaterial + gradient overlay (topLeading white @25% → bottomTrailing white @5%) + stroke white @30% 1dp + shadow black @20% r10 dy5. Transition: scale 0.9 + fade, spring 300ms.

### 2.4 Bottom controls (portrait), bottom padding 32dp, stacked with 12dp spacing:
1. **Segmented control** — "All | Indoor | Outdoor", height 36dp, width = min(available−32, 560), centered. **Replicate the iOS dark segmented picker, not Material3**: track = RoundedRect corner 9dp fill `#767680 @ 24%`, selected segment = corner 7dp fill `#636366` with subtle shadow (black @12% r4 dy2), labels 13sp medium white, thin 1dp separators between unselected segments at 30% white. Sliding thumb animates ~200ms.
2. **Row of 6 circular buttons** — size 44dp (40dp if screen ≤ 375dp wide), spacing auto-computed to fill width (clamped 6–20dp), horizontal padding 20dp (24 on small screens):

| # | Icon (SF Symbol) | Material equivalent | Size | Tint / states |
|---|---|---|---|---|
| 1 | `camera.rotate` | `Cameraswitch` | 22sp | white |
| 2 | `rectangle.3.offgrid` | custom drawable (2×2 offset-grid glyph; `Widgets` icon is closest stand-in) | 22sp | cyan `#64D2FF` when ultra-wide active, else white. Hidden (alpha 0, keeps layout slot) when front camera |
| 3 | torch: `flashlight.off.fill`/`flashlight.on.fill` | `FlashlightOff`/`FlashlightOn` | 20sp | yellow `#FFD60A` when on, else white; circle gets stroke yellow @ 50% 1dp when on / white @ 20% 1dp when off. Hidden when front camera |
| 4 | `ruler` | `Straighten` | 22sp | green `#30D158` when LiDAR/depth active, else blue `#0A84FF`. Hidden when unsupported/front camera |
| 5 | "🗣️" emoji text | (emoji) | 20sp | circle stroke green @50% 2dp when speech enabled, else white @25% 1dp |
| 6 | confidence: eye icon + "NN%" | `Visibility` | eye 20sp + 14sp bold rounded | white; VStack spacing 2 |

Circle button background (all): `.ultraThinMaterial @ 15%` over `black @ 25%` → Compose: circle `Color.Black.copy(alpha = 0.32f)` (+ optional backdrop blur).

### 2.5 Confidence slider popup (button 6 overlay)
Vertical slider (rotated −90°), track length 160dp × 32dp, iOS-blue thumb/track (`#0A84FF` active track, white round thumb 27dp, inactive track `#787880 @ 32%`), below it "NN%" 12sp bold white. Padding 10dp, drop shadow r8, positioned offset y −90dp above the button. Auto-dismisses ~100ms after drag release. Transition scale+fade spring.

### 2.6 Torch preset popup (button 3 overlay)
Vertical stack, spacing 8, of 4 buttons: 100% / 75% / 50% / 25%. Each: 60×36dp, RoundedRect corner 8, text 14sp medium white; selected: fill yellow @ 40%, stroke yellow 1dp; unselected: fill white @ 20%, stroke white @ 30% 1dp. Container: padding v8 h4, corner 12, material @ 80%, stroke white @ 20% 1dp. Positioned offset y −130dp above torch button. Tap torch when ON turns it off directly (no popup). Transition scale 0.95 + fade, 100ms easeOut.

### 2.7 Detection overlay (`DetectionOverlayView`) — THE signature look
Full-screen canvas above the camera, not touchable.

**Bounding boxes** — for each detection (rect is normalized 0–1, map directly to screen in portrait):
- RoundedRect **corner radius 12dp**, fill = objectColor @ **15%**, stroke = objectColor @ **50%**, width **2dp**.
- Box position/size animates with a spring (stiffness 150, damping 18 → Compose `spring(dampingRatio ≈ 0.74, stiffness = 150f)`) so boxes glide between frames.

**Color palette** (10 colors, exact):
```
#FF3366 hot pink   #00E5FF cyan      #80FF00 lime      #FF8000 orange    #CC00FF purple
#FFFF00 yellow     #0080FF sky blue  #FF0080 magenta   #00FF80 spring    #FFB300 gold
```
Color choice is **stable per tracked object**: djb2 hash of the detection's UUID string (`h = 5381; for each UTF-8 byte b: h = h*33 + b (u64 wrap)`), index = `h % 10`. Must replicate so colors don't flicker.

**Label chips**:
- Text: `"{classname lowercase} {confidence}%"`, plus `" {N}ft {L|C|R}"` when depth is available. E.g. `door 25% 13ft L`.
- Style: 14sp **bold rounded** white; padding h8 v3; capsule fill objectColor @ **25%**; text shadow black @ 30% r2 offset (1,1).
- Placement algorithm (replicate): estimated chip size = `(chars×9 + 24) × 28`dp; try in order: top-center of box (y = boxTop − 20), bottom-center (+20), box center, top-left, top-right; clamp inside screen; skip positions that intersect an already-placed chip; higher-confidence objects place first; fallback = grid offsets around box center (x offsets −100/0/+100, y +35 per row).
- Chip x/y animate with spring (stiffness 120, damping 15).
- Overall overlay fades detections in/out 150ms on count change.

---

## 3. Live OCR screens (`LiveOCRView`) — English mode & Spanish→English mode

Same screen, two configurations. Full-screen camera + pinch zoom. See screenshot `03_IMG_2875.png`.

### 3.1 Scrims
- Top: vertical gradient black @ 60% → transparent, height 120dp, flush to very top (behind cutout).
- Bottom: transparent → black @ 70%, height 250dp, flush to bottom.

### 3.2 Top bar (padding top safeTop + 15dp, horizontal = maxSafeSide + 20dp)
- **Back** pill (left): identical to §2.1 Back.
- **Mode chip** (right): text "English" or "Span → Eng", 14sp medium white, padding h12 v10, RoundedRect corner 20, material @ 85%.

### 3.3 Recognized-text card (above button row, only when text non-empty)
- Horizontal margin 20dp, padding 16dp, RoundedRect **corner 16**, `.ultraThinMaterial @ 95%` → `#262626 @ ~90%` + blur.
- Header row: status dot circle 8dp — **blue** `#0A84FF` before translation, **green** `#30D158` after · header text 14sp medium white @ 90% — "Detected" (English mode) / "Spanish Text" → "Translation" (Spanish mode) · trailing spinner when translating (see 3.6).
- Body: scrollable text 16sp white, max height 100dp, left-aligned.
- Enter/exit: slide from bottom + fade.
- In Spanish mode after translation, tapping the card opens the Translation popup (light haptic).

### 3.4 Bottom button row — 6 circle buttons, same geometry/background as §2.4:
| # | Icon | Material | Notes |
|---|---|---|---|
| 1 | `gearshape.fill` | `Settings` | opens Settings overlay |
| 2 | `flashlight.off/on.fill` | `FlashlightOff/On` | yellow when on; tap-on shows preset popup (§2.6, offset y −90 here) |
| 3 | `rectangle.3.offgrid` | custom | cyan when ultra-wide |
| 4 | `character.book.closed.fill` (translate; Spanish mode pre-translation) → else `doc.on.doc.fill` (copy) | `Translate` / `ContentCopy` | 60% alpha while translating |
| 5 | `person.wave.2.fill` (speak) | `RecordVoiceOver` | while speaking: circle fill green @ 30%, button scales to 1.1×, 200ms easeInOut |
| 6 | `arrow.clockwise` (reset) | `Refresh` | clears text/translation, stops speech |
All icons 22sp white (except state tints above). Bottom padding 32dp.

### 3.5 Translation Ready popup (`TranslationActionsPopup`, Spanish mode)
- Scrim: black @ 40% full-screen; tap = "Continue".
- Card: maxWidth 320dp, padding 24dp, RoundedRect corner 20, ultraThinMaterial (dark glass + blur), stroke white @ 20% 1dp, shadow black @ 30% r20 dy10. Enter: scale 0.9→1 + fade.
- Title: "Translation Ready" 20sp semibold white, centered. 20dp below → button stack spacing 12:
  - Each button: full-width, vertical padding 14dp, RoundedRect corner 14, HStack centered (icon 18sp + label 17sp medium), white content.
  - "Copy Translation" — `doc.on.doc.fill`/`ContentCopy` — fill blue @ 30%, stroke blue @ 50% 1dp.
  - "Continue Reading" — `eye.fill`/`Visibility` — green @ 30% / green @ 50%.
  - "New Scan" — `arrow.clockwise.circle.fill`/`Refresh` (circled) — orange @ 30% / orange @ 50%.

### 3.6 AnimatedLoader (spinner)
Circular: background ring white @ 18%, arc stroke = **angular (sweep) gradient purple→blue→cyan→purple**, round caps, line width 6 (at default 36dp; used at 22dp in text card ×0.8 scale). Arc sweeps between 0.08–0.96 of the circle (easeInOut 0.95s autoreverse) while rotating 360° linearly every 1.1s.

### 3.7 Settings overlay (`SettingsOverlayView`)
- Scrim black @ 40%, tap or swipe-down (>80dp) dismisses; spring scale 0.9↔1 + fade.
- Card: maxWidth 380dp, maxHeight 600dp, corner 20, ultraThinMaterial @ 80% (dark glass + blur), stroke white @ 20% 1dp, shadow r20. Centered.
- Header (padding 16): "Settings" 22sp semibold white — Spacer — close button `xmark.circle.fill` 22sp, hierarchical secondary gray (`Cancel` icon, tint `#8E8E93`). Divider @ 50% opacity below.
- Scrollable content, padding 16, section spacing 20. Every section card: padding 16, RoundedRect corner 12, fill material @ 30% (`#3A3A3C @ ~35%`).
  - **Copy History** (OCR only): header row — `doc.on.clipboard`/`ContentPaste` 20sp orange · "Copy History" 17sp semibold white · Spacer · "Clear" 12sp red (only if non-empty). Empty state: "No copied text yet" 17sp secondary, centered, v-padding 20. Rows (spacing 8): text 17sp **Roboto Mono**, max 2 lines, + trailing copy icon `doc.on.doc` blue; after tap → `checkmark.circle.fill` + "Copied" 12sp bold, green, for 1.2s. Row: padding 12, corner 8, material @ 20%.
  - **Camera Zoom** row (only when zoomed): `camera.viewfinder`/`CenterFocusStrong` 20sp purple · "Camera Zoom" headline · Spacer · "1.5x" 20sp rounded medium purple.
  - **Tips** card: header `info.circle` 20sp blue + "Tips" headline; then 13sp secondary lines: "• 🤏 Pinch to zoom the camera", "• 📋 Copy detected/translated text", refresh-icon + "Reset/Stop — Clears text, translation, and stops speaking", "• 🗣️ Speak detected/translated text", "• 🔦 Adjust flashlight", "• 🌎 Toggle wide/ultra-wide lens", "• ⚙️ Open settings/history".
  - **Private by Design** card: `lock.shield`/`Security` 22sp semibold green + "Private by Design" headline; 4 icon+text rows 15sp secondary: airplane/`Flight` "Works 100% offline — even in Airplane Mode"; `eye.slash`/`VisibilityOff` "No tracking, no analytics, no accounts"; `camera.viewfinder` "Camera frames are processed on-device only"; `doc.on.clipboard` "Copy history stays on this device (you can clear it anytime)". Extra stroke white @ 15% 1dp on this card.

---

## 4. Instructions screen (`AppInstructionsView`)
iOS modal sheet → Compose `ModalBottomSheet` (full-height, rounded top ~10dp, drag handle) or full-screen dialog with iOS-sheet styling. Dark background `#1C1C1E`.
- Nav bar: title "Instructions" (iOS large-title behavior; acceptable: 17sp semibold centered) + "Done" text button (17sp, iOS blue) top-left area (iOS `cancellationAction` = leading). Done stops audio + dismisses; swipe-down also stops audio.
- Content: ScrollView, padding 24dp, spacing 20:
  1. "👋 Welcome to RealTime AI Camera!" — 34sp bold white.
  2. Play/Stop button: full-width, padding 16, corner 12, fill blue @ 18% (red @ 18% while speaking); HStack spacing 8: icon `speaker.wave.2.fill`/`VolumeUp` (or `stop.fill`/`Stop`) + "🎧 Play Full Audio Tutorial" / "⏹ Stop Audio" semibold 17sp white.
  3. Tagline "Snap, Detect, Translate — all on-device." 20sp.
  4. "✨ **Modes**" 17sp semibold; then three blocks (titles 22sp semibold, bodies 17sp): 🐶/🐕 Object Detection (+ LiDAR sub-line), 🔠 English OCR, 🇲🇽→🇺🇸 Spanish to English Translate. Bold spans use markdown-style bold.
  5. "🎛️ **Controls**" headline + 8 body lines (🔄 Switch Camera…, 🌐 Lens Toggle…, 🔦 Torch — 25% / 50% / 75% / 100%, 🤏 Pinch to Zoom, refresh-icon Reset/Stop line, 🗣️ Speak…, 📋 Copy to History, ⚙️ Settings).
  6. "🔒 **Privacy First**" headline + 4 lines, all in `.secondary` gray.

---

## 5. App icon & launch
- Icon source: `design/app-icon-1024.png` (black-background icon). Generate all mipmap densities; adaptive icon foreground = icon art, background = black `#000000`.
- Launch/splash: Android 12 SplashScreen API with black background + app icon, then straight into Home (Home itself is the branded "splash" look).

---

## 6. SF Symbol → Material icon master table

| SF Symbol | Material Icons (Extended) | Note |
|---|---|---|
| chevron.left | `ArrowBackIosNew` | 16sp, bold weight — scale to match |
| chevron.up / chevron.down | `KeyboardArrowUp` / `KeyboardArrowDown` | |
| speedometer | `Speed` | |
| eye / eye.fill | `Visibility` | outline vs filled |
| eye.slash | `VisibilityOff` | |
| camera.rotate | `Cameraswitch` | |
| rectangle.3.offgrid | **custom drawable needed** (3 offset rounded squares); closest stock `Widgets`/`GridView` | draw custom for exactness |
| flashlight.on.fill / flashlight.off.fill | `FlashlightOn` / `FlashlightOff` | |
| ruler | `Straighten` | |
| gearshape.fill | `Settings` | |
| doc.on.doc / doc.on.doc.fill | `ContentCopy` | |
| doc.on.clipboard | `ContentPaste` | |
| person.wave.2.fill | `RecordVoiceOver` | |
| arrow.clockwise | `Refresh` | |
| arrow.clockwise.circle.fill | `Refresh` in filled circle | compose Box with circle bg |
| character.book.closed.fill | `Translate` (or `MenuBook`) | translate action |
| xmark.circle.fill | `Cancel` | tint `#8E8E93` |
| camera.viewfinder | `CenterFocusStrong` | |
| info.circle | `Info` (outlined) | |
| lock.shield | `Security` / `VerifiedUser` | |
| airplane | `Flight` | |
| checkmark.circle.fill | `CheckCircle` | |
| speaker.wave.2.fill | `VolumeUp` | |
| stop.fill | `Stop` | |

---

## 7. Differences that are unavoidable (document, don't fight)
1. **LiDAR**: no Android depth sensor equivalent on most phones. The ruler button + "ft L/C/R" label suffix should be hidden (alpha 0, slot preserved — exactly what iOS does on non-LiDAR iPhones). Optionally back it with ARCore Depth API on supported devices.
2. **Status bar / Dynamic Island**: iOS hides the status bar and the island punches through screenshots. Android: hide status bar, draw behind the camera cutout; the cutout shape will differ per device.
3. **`.ultraThinMaterial` blur**: true backdrop blur only on Android 12+ (`RenderEffect`); below that, translucent surfaces without blur — colors specified above keep the look close.
4. **Emoji glyphs**: Google emoji differ from Apple's (📖🐶🗣️ etc.). Acceptable, or ship Apple-style PNGs for the 3 home buttons.
5. **Fonts**: SF Pro / SF Rounded → Roboto / Nunito Sans; metrics differ ±2%; keep the specified sp sizes.
6. **Voices**: iOS lists Siri/AVSpeech voices ("Samantha (Enhanced)" etc.). Android must populate the same picker UI from `TextToSpeech.getVoices()` — names will differ; keep the "(Enhanced)"-style quality tag when `Voice.quality ≥ QUALITY_HIGH`.
7. **Spanish translation engine**: Apple Translation framework → ML Kit on-device translation (also offline; keep the same "translate → popup" flow).
8. **Haptics**: Android haptic hardware varies; use `KEYBOARD_TAP`/`CONFIRM` as closest matches.
9. **iOS segmented control & sheet chrome**: build custom Compose versions per §2.4 and §4 — Material 3 defaults would immediately break the "identical" requirement.
10. **601-class detection model**: current iOS build uses a YOLOv8-based 601-class model via CoreML; Android needs a TFLite/ONNX conversion — visual overlay spec (§2.7) is unchanged regardless of model.

---

## 8. Screen-by-screen implementation checklist (by user impact)

1. **Home screen** — background image, heading pill, 3 glass capsule buttons w/ exact gradients+strokes+glows, INFO/GUIDE pill, voice picker pill, version label, staggered entry animation. (First thing every user sees; the whole brand.)
2. **Object Detection screen** — camera preview, detection overlay (10-color palette, 15% fill / 2dp 50% stroke / r12 boxes, capsule label chips, spring motion, stable hash colors), FPS + object-count chips, Back pill, segmented All/Indoor/Outdoor, 6-button control row, confidence slider popup, torch popup, zoom pill.
3. **English OCR screen** — top/bottom scrims, Back + mode chips, glass text card w/ status dot, 6-button row, torch popup, spinner.
4. **Spanish OCR extras** — translate button state machine, Translation Ready popup (3 colored glass buttons), green "Translation" state, copy haptics.
5. **Settings overlay** — glass card, Copy History (max 5, monospace, Copied state), zoom row, Tips card, Private-by-Design card, swipe-down dismiss.
6. **Instructions sheet** — first-launch auto-show + INFO button, audio tutorial play/stop button, full copy text per §4.
7. **Voice picker grid** — 2×5 grid popup, selection + welcome speech.
8. **Polish pass** — entry animations, haptics everywhere specified, debounce (0.5s buttons / 1.0s back), landscape layouts (§2.1 landscape chips, rotated control column at left side, rotationEffect equivalents), scene lifecycle (reset to Home on background, resume camera on return).

---

## 9. Behavioral notes an implementer must not miss
- Buttons everywhere are **debounced**; double-taps must be ignored.
- Back from a camera mode: stop camera + speech, clear detections/text, torch off, return Home.
- App backgrounded → full reset, mode forced to Home.
- OCR: frame processing pauses during pinch and during translation.
- Copy history: last 5 unique strings, newest first, persisted (SharedPreferences), viewable/clearable in Settings.
- Confidence slider range is 0.0001–1.0, displayed as integer %.
- Speech announcements in Object Detection are toggleable via the 🗣️ button (green ring when on).
- Torch presets set the *strength* (Android: `CameraControl.enableTorch` has no level on most devices — use `setTorchStrengthLevel` on Android 13+/supported hardware, else on/off; keep UI identical).
