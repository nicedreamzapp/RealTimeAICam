# Contributing

Thanks for taking a look. This app is used every day by blind and low-vision people, so reports
from real screen reader use are the most useful thing anyone can send, even without code.

## Reporting a problem

Open an [issue](https://github.com/nicedreamzapp/RealTimeAICam/issues/new/choose). The things that
make it quick to fix:

- iPhone or Android, your phone model and OS version, and the app version
- whether VoiceOver or TalkBack was on, and which voice the app was using
- which feature (detection, *What's this?*, live reading, mail and bill mode, Spanish translation,
  Help Me Aim, LiDAR distance)
- what it said, and what it should have said
- a screenshot, screen recording or crash log if you have one (leave out photos of personal mail)

If a control is unlabelled or read in the wrong order, that is a bug, so please report it.

## Running it locally

```bash
git clone https://github.com/nicedreamzapp/RealTimeAICam.git
cd RealTimeAICam/ios
open "RealTime Ai Cam.xcodeproj"
```

You need macOS with Xcode 16 or later. Pick your own signing team and bundle identifier under
Signing & Capabilities before you run on a device. The narrator weights are not in the repo, so
*What's this?* shows a **Download** button on first use.

For Android, build the llama.cpp libraries and model files first by following
[android/NARRATOR.md](android/NARRATOR.md), then open `android/` in Android Studio.

## Tests

- iOS: unit tests in `ios/project 601Tests/` (Help Me Aim, money cross-check, speakable text and
  more). Run them from Xcode with the test action.
- Android: unit tests in `android/app/src/test/`. Run them from Android Studio.

Also check your change by hand on a real phone with VoiceOver or TalkBack turned on.

## Pull requests

Small and focused is easiest to review. Say which devices and OS versions you tested on, and
whether you tried it with a screen reader. For big changes, open an issue first so we can talk it
through.

Please follow the [code of conduct](CODE_OF_CONDUCT.md).
