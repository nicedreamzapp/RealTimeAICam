# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report them privately through GitHub: go to the **Security** tab of this repo and click **Report a vulnerability** ([direct link](https://github.com/nicedreamzapp/RealTimeAICam/security/advisories/new)). Only the maintainer sees the report.

Helpful details: what you found, how to reproduce it, the app version and store (App Store or Google Play) or the commit, and your phone model and OS version.

I aim to reply within 3 days and to ship a fix or a clear plan within 30 days, depending on severity. You will be credited in the advisory unless you ask not to be.

## Supported versions

Fixes go into the latest App Store and Google Play builds, made from `main`. Please update the app before reporting if you are on an older version.

## What matters most here

The parts where a mistake could hurt someone:

- the narrator model download in `ios/project 601/VisionModelStore.swift`, which checks size and hash against the manifest made by `tools/make_manifest.py`
- camera, microphone and photo library access, declared in `ios/RealTimeAiCam-Info.plist`, `ios/PrivacyInfo.xcprivacy` and `android/app/src/main/AndroidManifest.xml`, since the app promises nothing leaves the phone
- the native llama.cpp bridge in `android/app/src/main/cpp/narrator_jni.cpp`
- reading money amounts and deadlines out loud in `ios/project 601/MailSummarizer.swift` and `MoneyCrossCheck.swift`, where a wrong number could mislead a blind user
