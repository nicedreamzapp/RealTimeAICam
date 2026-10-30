# Live Room Mode: a plan for RealTime AI Cam

**Summary**
- Goal: hold the phone up and the app narrates the room, remembers what it said, and only speaks for things that are new, moved, or dangerous. Fully offline.
- Feasible today on iPhone 15 Pro and newer: the fast detector already runs at 15 to 30 frames a second and the vision model answers in about 1.6 seconds.
- Partly feasible on 2020 to 2022 iPhones: the detector loop works, the vision model is a change-triggered helper every 15 to 20 seconds.
- Budget Android gets the detector loop, the no-repeat memory and hazard alerts; the vision model stays a tap-to-ask tool.
- First milestone: a working prototype on the iPhone 18 Pro Max in about two weeks.

## 1. The vision

Point the phone at a room and leave it there. Every few seconds the app tells you what is in front of you and where: "Kitchen table ahead, two chairs on the left, a doorway on the right." Then it goes quiet. It does not say "table" again. When something changes, a person walks in, a cup appears on the counter, it says just that one new thing. Over time the app should know not six hundred kinds of things but twenty thousand, and every release should make it sharper. Nothing leaves the phone.

## 2. Feasibility, honestly

Two engines are in play, at very different speeds.

**The fast detector.** The app ships a 601-class detector (YOLOv8 nano, 640 by 640, on the Neural Engine). New iPhones process every frame; older phones already skip to every 2nd, 4th or 6th frame. It returns boxes with a name and a position, a LiDAR distance is attached on Pro phones, and a tracker already matches boxes frame to frame. That tracker is the seed of the "seen list."

**The vision language model.** The new Liquid 2B model gives a real sentence about a photo, including things the detector has no label for. Measured on one photo, ninety-token answer:

| Phone class | Full answer | Realistic cadence |
|---|---|---|
| iPhone 18 Pro Max (roughly 15 Pro and up) | 1.6 s | every 3 to 4 s, with gaps for speech |
| iPhone 12 Pro Max | 13.8 to 18.5 s | every 15 to 20 s, on scene change only |
| Budget Android (Helio P35, CPU) | 73 to 186 s | on request only |

The physics: the detector is a 20 to 30 frames per second loop, the vision model is a once-every-few-seconds loop on new phones and a once-a-minute loop on old ones, and speech is its own loop that cannot be rushed because a person has to hear it. So the fast loop carries the "new thing appeared" job on every phone, and the slow loop adds layout and richer names only as often as the phone can afford. Memory is fine (450 to 620 MB peak with the model loaded). Heat over ten minutes is the real unknown.

## 3. Architecture

**Detector, every processed frame.** The 601-class model runs as today. Its output feeds the tracker, not the speaker.

**Tracker.** The existing tracker gains a stable ID per object, an age, and a "confirmed" state after a few consecutive hits, so a flickering box is never announced.

**Seen list with spatial memory.** Each confirmed object gets a name, a bearing (left, ahead, right, from its frame position plus the phone's heading), a distance where LiDAR gives it, and the time it was last spoken. ARKit on iOS and ARCore on Android supply heading and position, so if you turn ninety degrees and back, the table is still the same table. Without AR pose, the compass and gyroscope are enough for left, ahead, right. Entries expire only after an object has been out of view for a long time.

**Vision model on a slow cadence, gated by change.** It runs only when the scene has changed: a cheap frame difference plus the motion sensors say the phone or something in front of it moved, or the tracker confirmed a new object worth naming better. On new phones that still gives a 3 to 4 second rhythm when you pan; on old phones it keeps the model asleep most of the time. Prompts are short deltas: the photo plus a one-line list of what has been said, and "what is new or different, in one sentence, or say nothing." The fixed part of the prompt is cached, so it costs nothing after the first run.

**Speech arbitration.** One speaker, one queue, three priorities. Hazards (stairs, curb, step down, a person or vehicle closing in, a door edge, a dog) interrupt anything. New objects are spoken when the speaker is free, merged into one sentence when several arrive together ("chair and lamp on your left"). Layout sentences are lowest priority and are dropped, not delayed, if a newer one is ready. The app never talks over itself and never repeats a seen-list entry unless the user asks "what's around me."

## 4. From 601 to 20,000

Three stages, and the second is already in the repo.

1. **601 classes, today.** Fast and reliable.
2. **Open-vocabulary detector, next.** A prompt-free YOLOE model already sits in the iOS project for the Help Me Aim feature. It knows about 4,500 names out of the box, runs on the Neural Engine in the same loop, and can be taught new names at runtime. Promoting it to the main detector is the biggest single step, at no vision-model cost. The work is a side-by-side benchmark against the 601 model and a frame-rate check on an A14 phone.
3. **The vision model names the rest.** Anything the detector sees but cannot name confidently gets cropped and sent to the vision model with "name this in two words." The answer is written into the seen list and remembered for that object's lifetime. About half a second per crop on new iPhones; old phones queue at most one crop every ten seconds.

Twenty thousand is realistic as "the detector knows thousands, the vision model fills in the rest on demand." A single on-device detector with twenty thousand labeled classes is not realistic this year, and the plan does not depend on it.

## 5. Build plan

**M1, prototype on iPhone 18 Pro Max (about 2 weeks).** Detector, tracker, flat seen list, vision model every 4 seconds with a delta prompt, one speech queue. Done when a blind tester hears a layout sentence within five seconds of pointing at a room, then holds still for a minute and hears nothing repeated.

**M2, spatial seen list and no-repeat (about 2 weeks).** ARKit pose, bearings, distance, expiry rules. Done when the tester turns a slow full circle and back and hears each object once with a correct left, ahead or right, and a chair moved across the room is announced as moved.

**M3, hazard priority and tuning (about 2 weeks).** Hazard classes, interrupts, cool-downs, merged sentences, the "what's around me" recap. Done when a person walking toward the tester is announced within two seconds even mid-sentence, and the tester counts no more than one unwanted alert per ten minutes in a quiet room.

**M4, Android and older iPhones (about 3 weeks).** Frame skipping, ARCore or sensor fallback, scene-change-only vision model, 512 pixel input and cached prefix on budget phones. Done when the M2 and M3 tests pass on an iPhone 12 Pro Max and a Helio P35 phone, with slower layout sentences allowed but no repeats and no missed hazards.

**M5, open vocabulary (about 3 weeks).** YOLOE as the main detector where frame rate allows, vision-model naming for unknown crops. Done when the tester hears correct names for ten household items not in the 601 list, and the newest iPhone stays above 15 frames a second.

Each milestone ships as its own release, so the app improves every few weeks.

## 6. Risks and unknowns, as tests

- **Heat and battery.** Ten minutes of detector plus vision model on the newest iPhone and the 12 Pro Max; log battery drop and thermal state. Pass: under 15 percent battery and no throttling on the new phone.
- **False alerts.** Thirty minutes in a quiet room on a stand. Anything spoken after the first layout is a false alert. Target under one per ten minutes.
- **Hazard latency.** A person walks toward the phone during a layout sentence. Measure first frame to first word. Target under two seconds new, under four old.
- **Re-identification.** Look away and back ten times. Target zero re-announcements.
- **Engine lock.** The model answers one at a time, so measure how long a "what's this" tap waits behind a running description. Over three seconds means taps must cancel it.
- **Open-vocab speed.** YOLOE frame rate on an A14 phone and a budget Android, same frames as the 601 model.
- **Blind-tester judgement.** Every "done when" is scored by a blind tester, not a sighted developer watching the screen.
