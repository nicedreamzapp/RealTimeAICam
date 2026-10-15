# RealTime AI Cam: press kit

Draft for Matt to review. Anything marked **TODO-VERIFY** needs a check before it goes out.

Landing page: [`index.html`](index.html) in this folder. Screenshots and icon are the existing files in this repo, listed at the bottom.

## Fact sheet

| | |
|---|---|
| **Name** | RealTime AI Cam (also written RealTime AI Camera) |
| **Developer** | Matt Macosko / Nice Dreamz (Nice Dreamz LLC) |
| **Platforms** | iPhone, iOS 17 or later. Android 8 or later; What's this? needs Android 9+ on a 64-bit (arm64) phone |
| **Price** | Free. No ads, no subscription, no in-app purchases |
| **App Store** | https://apps.apple.com/us/app/id6751230739 |
| **Google Play** | https://play.google.com/store/apps/details?id=com.mattmacosko.realtimeaicam |
| **Source code** | https://github.com/nicedreamzapp/RealTimeAICam (AGPL-3.0; name and icon not licensed) |
| **Demo video** | https://www.youtube.com/watch?v=2BEYv-fv-gE (90 seconds) |
| **Current versions in the repo** | iOS 1.3.4 (build 39), Android 1.17 (versionCode 22). **TODO-VERIFY:** which of these is live in each store today |
| **Download size** | iPhone: around 700 MB, because the description model ships inside the app (README). The model alone is 622 MB on disk (`VisionModelStore.swift`) |
| **Object classes** | 601, from Open Images V7 |
| **Translation** | Spanish to English built in and offline. iOS 18+: up to 16 more languages via Apple's on-device translator. Android: 9 more via Google ML Kit packs. Extra languages download once, then work offline |
| **Data collected** | None (see `PRIVACY.md`) |
| **Contact** | info@nicedreamzwholesale.com |
| **More apps** | https://nicedreamzwholesale.com/software/ |

### Release history

There are no git tags or GitHub releases in this repo. This list comes from version-bump commits in `git log`. The repo history starts on 2026-06-04, so earlier releases are not in it.

**TODO-VERIFY:** first App Store release date. Screenshots in the repo are dated 2025-08-10 (EXIF in `ios/IMG_2224.jpeg`) and 2025-09-02 (file name), and `NOTICE.md` says copyright 2025-2026, so the iPhone app was out before this history begins.

| Date | Platform | Version | What changed (from the commit message) |
|---|---|---|---|
| 2026-07-06 | iOS | 1.0.15 (18) | Privacy manifest fix for App Review |
| 2026-07-06 | iOS | 1.0.16 (19) | Translation overhaul, speed and stability batch |
| 2026-07-13 | Android | first port | Android port added; privacy policy published |
| 2026-07-24 | Android | live | First live on Google Play (commit "now also live on Google Play"). **TODO-VERIFY:** a later commit says all four apps approved 2026-08-04 |
| 2026-09-08 | Android | 1.2 (7) | What's this? vision narrator on Android |
| 2026-09-09 | Android | 1.3 (8) | What's this? rebuilt to match the iPhone, Vulkan GPU path |
| 2026-09-12 | iOS | 1.2.0 (24) | AppleVis feedback: countdown, one-tap torch, never refuse a photo |
| 2026-09-12 | Android | 1.4 (9) | Same AppleVis fixes as the iPhone |
| 2026-09-15 | Android | 1.6 (11) | Build live on Google Play at the time |
| 2026-09-16 | iOS | 1.2.1 (28) | Info Guide crash fix, flashlight off on leave |
| 2026-09-21 | iOS | 1.3.0 (35) / 1.3.1 (36) | Help Me Aim, more translation languages, follow-up answers say the answer first |
| 2026-09-23 | iOS | 1.3.2 (37) | Siri shortcuts, Help Me Aim saves the photo with its caption |
| 2026-09-27 | iOS | 1.3.3 (38) | Blind Android Users tester fixes, centered Help Me Aim shots |
| 2026-10-06 | Android | 1.17 (22) | Live Play source synced into the repo |
| 2026-10-06 | iOS | 1.3.4 (39) | Numbers, phone numbers and addresses spoken like a person |

## 50-word description

RealTime AI Cam is a free iPhone and Android camera app that tells you what it sees, out loud. It describes scenes and mail, reads printed text, translates signs, names 601 kinds of objects and helps blind photographers aim. Everything runs on the phone, offline, with no account or ads.

## 150-word description

RealTime AI Cam is a free iPhone and Android app that turns the camera into a voice. Press What's this? and it says, in one to three plain sentences, where you are, what is near you and on which side, and any hazards. Point it at a letter and it leads with who sent it, the amount, and the deadline. Hold the button to ask a follow-up question.

It also reads printed text aloud, translates Spanish and other languages into English, detects 601 kinds of objects with distances on LiDAR iPhones, and has Help Me Aim, which tells a blind photographer which way to move the phone and then takes the picture.

The description model is a fine-tuned build of Qwen3.5 that ships inside the app and runs on MLX Swift on iPhone and llama.cpp on Android. No account, no ads, no data collected, and it works in airplane mode.

## Five features

- What's this? describes a scene, page or bill out loud, and answers a spoken follow-up question.
- Help Me Aim talks you into the shot for a face, a page or an object, then takes it.
- Live text reading with numbers, phone numbers and addresses spoken the way a person says them.
- Offline translation into English: Spanish built in, more languages after a one-time download.
- 601-class object detection with Indoor and Outdoor modes and LiDAR distance on Pro iPhones.

## Pitch email template

Subject: Free camera app that describes mail and rooms out loud, offline

> Hi [name],
>
> Point the phone at a bill and it says who sent it, how much, and when it's due. That's What's this? in RealTime AI Cam, and it runs on the phone with no internet.
>
> The model behind it is a small Qwen3.5 I fine-tuned for this one job. It ships inside the app, so it works in airplane mode and nothing gets uploaded. The same app reads text out loud, translates signs into English, names objects, and has Help Me Aim, which tells a blind photographer which way to move until the shot is framed and then takes it.
>
> A lot of it came from requests on AppleVis and from Blind Android Users testers. It's free on iPhone and Android with no ads and no account.
>
> App Store: https://apps.apple.com/us/app/id6751230739
> Google Play: https://play.google.com/store/apps/details?id=com.mattmacosko.realtimeaicam
> 90 second demo: https://www.youtube.com/watch?v=2BEYv-fv-gE
> Source: https://github.com/nicedreamzapp/RealTimeAICam
>
> Happy to send screenshots or answer questions.
>
> Matt Macosko
> Nice Dreamz
> info@nicedreamzwholesale.com

## Credits for upstream work

Please keep these in any write-up that goes into how it works. Matt wrote the app; these projects supplied the models and runtimes.

- **YOLOv8** and **YOLOE** by Ultralytics: object detection and Help Me Aim's object finder
- **Open Images V7** by Google: the 601 classes
- **Qwen3.5** by the Qwen team: base model for the LoRA fine-tune. **TODO-VERIFY:** training code is not in this repo, so the tool used for the fine-tune (for example mlx-vlm or mlx-lm) is not stated anywhere here. Name it if it should be credited
- **MLX Swift** and **mlx-swift-lm** (ml-explore): run the model on iPhone
- **swift-transformers** and **swift-huggingface** by Hugging Face: tokenizer and model loading on iPhone
- **llama.cpp** by ggml-org: runs the model on Android
- **Core ML, Vision, ARKit, Apple Translation** by Apple; **TensorFlow Lite, ML Kit, Jetpack Compose** by Google
- **Anthropic Claude Code**: the git history has commits co-authored by Claude. **TODO-VERIFY:** whether Matt wants that mentioned in press copy

## Numbers used, and where they come from

| Claim | Source |
|---|---|
| 601 object classes | `ios/class_names.txt`, `YOLOv8Processor.swift`, README |
| Around 700 MB iPhone download | README, Requirements |
| 622 MB model on disk | `ios/project 601/VisionModelStore.swift` |
| About 87 s per What's this? answer on a Helio P35 Android phone | `android/NARRATOR.md` (only phone timed) |
| Up to 16 extra iOS translation languages | `ios/LiveOCRViewModel.swift`, `appleCandidates` |
| 9 extra Android translation languages | `ReaderLanguages.kt` |
| iOS 17+, Android 8+ (minSdk 26) | `project.pbxproj`, `android/app/build.gradle.kts` |

Not used on purpose: download counts (the README badge is live and changes), the "~10 FPS" README badge (older screenshots show 30 FPS on screen, so the figure needs a fresh measurement, **TODO-VERIFY**), star counts, ratings, reviews.

## Assets in the repo

| File | What it shows |
|---|---|
| `android/design/app-icon-1024.png` | App icon, 1024 x 1024 |
| `ios/HomeSCreen1.png` | Home screen with voice picker |
| `ios/IMG_2208.png` | Object detection on a face |
| `ios/IMG_2169.png` | Handwritten Spanish chalkboard menu translated |
| `android/design/appstore-screenshots/03_IMG_2875.png` | Printed Spanish menu translated |
| `ios/IMG_2247.png` | LiDAR distances in a room |
| `android/design/appstore-screenshots/07_ipad12.png` | iPad-size home screen |

**TODO-VERIFY:** all of these predate What's this? and Help Me Aim, and show an older home screen. New screenshots of those two features would help most. The PNGs are 1 to 10 MB each; resize before uploading the landing page to the website.
