# Live Cam: what it must do (Matt's rules)

Every Live Cam change is checked against this file before it ships. If a plan step contradicts a line here, ask Matt first.

Approved by Matt on 11/09/2026 at about 5:05 AM: "it feels like this is what i want please bake this in."

1. **Open: one short general read of the room.** No greeting, welcome, "experimental" warning, name, or "anything I can help with?".
   - 11/09 4:50 AM: "it should say what it sees in the screen from the get go, just a general read of the room."
   - 11/09 1:18 AM: "there's some sort of like welcome narration. I don't want that."
   - 11/06 3:55 AM: "it's saying like an introduction, like welcome to live cam ... It doesn't need to introduce itself."
   - 11/06 2:56 AM: "what is that warning welcome i dont want that."
   - A missing hand-picked model is named once, in front of that first read, never as a separate line.
2. **Always watching.** It analyzes the camera constantly in the background: the fast on-phone detector about every second (slower when the phone runs hot), the vision model only when something is new.
   - 11/09 ~5:00 AM: "it's got to kind of always be taking photos and analyzing them, kind of constantly."
3. **Only new things, once each.** "Now I see a dog." "A car is driving by." A tree, a street. It never repeats what it already told (the table, a wooden wall, the same chair, the same person). Moving the camera over known things says nothing. A thing must show on two checks in a row before it counts, and unprompted lines are at least 7 seconds apart.
   - 11/09 ~4:55 AM: "When new things come into view, it should describe those new things, but it shouldn't keep saying that it sees a table every time, and it shouldn't be saying it sees a wooden wall or its chair the same chair or the same person."
   - 11/09 ~5:00 AM: "if it sees a dog, it says, oh, now I see a dog. Or a tree or a street or a car driving by or just something new coming into the view."
   - Fresh memory when Live Cam closes or he walks into a different room.
4. **He speaks = priority.** A question ("what color shirt am I wearing?") or a goal pauses the watch; a fresh frame answers it; then watching resumes.
   - 11/09 ~5:00 AM: "if someone speaks or asks it something, that's when it has a direction and gets queued to do something. Like if I asked it what color shirt I was wearing, then it would focus on that answer and use the camera to help it."
5. **Repeat questions.** "What do you see" again leads with what's new ("Same as before." when nothing is); a full re-description only if he asks for everything again.
   - 10/31: "I don't want it to repeat analogies unless the scene changes."
   - 11/09 ~4:55 AM: "It maybe can describe newer things about the scene, but it can't keep saying the same thing."
6. **Never on screen: no snapshot, freeze, shutter flash, sideways still or yellow box, in any mode.** The live preview stays live; the frame goes only to the model.
   - 10/31: "does it make the screen pause for a second? ... I don't want it. I don't want there to be any indications."
   - 11/08: "you can see it actually snapping the picture. I don't want to do that. It's gotta be invisible ... look and feel live."
   - 11/09 4:29 AM: "i asked for it not to make snapshot and it still does ... I told you not to make it happen in any mode."
7. **No nagging.** Check-ins ("What are you up to?") are off by default (the Speak up when quiet switch turns them on); help is never offered unprompted.
   - 11/06 2:57 AM: "i dont want it to keep asking if it can help constantly ... should not repeat phrases."
8. **Interrupts.** Only a real question or a stop word stops it talking, not a cough or a murmur.
   - 11/06 2:58 AM: "It shouldn't stop speaking when it hears me cough ... only ... a legitimate question."
9. **Keep:** the flashlight (button and voice), zoom (pinch and 1×/2×), Back and the VoiceOver escape (two-finger Z), and the words-on-screen switch (in Settings > Live Cam).
   - 11/06 3:21 AM: "Live cam needs to have a flashlight."
   - 11/02: "I put two fingers and I spread them apart and that zooms in."
   - 11/09 1:02 AM: "When you're in live camera, how do you get back to the home screen."
10. **No Ask button, always listening.**
    - 11/09 ~5:10 AM: "there is an ask button i not want that, it should be listen always."
    - Typing appears only when it can't listen (no microphone or speech permission, recognition stopped, or the microphone switched off in Settings).
11. **Layout and Quiet.** Bottom: Flashlight (back camera only, hidden on the selfie camera), Quiet (white) and Back (red), icons only, in a slim translucent bar at the very bottom like the Camera app (about 48 to 52 pt circles, never under 44). Top: small icon buttons in the corners, the mode menu and flip camera, no words. Words on screen are off by default (the switch and the microphone switch live in Settings > Live Cam). Every button has a plain-word VoiceOver label.
    - 11/09 ~6:00 AM: "The flashlight shouldn't appear for the front camera. Also, the buttons are too big and the text that is showing up on the screen shouldn't show up on the screen until you hit quiet."
    - 11/09 ~6:00 AM: "Screen should be clear of text."
    - Asked for the flashlight by voice on the selfie camera, it says "The flashlight works with the back camera." and never flips on its own.
    - **Quiet** (11/09 ~5:20 AM, "Yes, that"): one tap stops it talking right away; from then on everything it would say (the read of the room, new things, answers) shows as words only, with no voice and no VoiceOver announcements. It keeps watching and listening. Tap again to speak out loud. Remembered across visits. VoiceOver: "Quiet, off" / "Quiet, on", hint "Show words instead of speaking".
12. **A clear view.** No green circle in the middle; its state is for VoiceOver only, and his turn is a light tap. The zoom pills (1×/2×) sit small and centered just above the bottom bar, where the Camera app has them; pinch still zooms. With Quiet on, the words go just under the top buttons, never over the middle: the newest line only, two or three lines at most, fading a few seconds after they land.
    - 11/09 ~6:05 AM: "always [clear of text] unless you hit quiet, but then it strategically places [the text]. Also I don't need a green circle in the middle of the app. Also buttons are too big for the app and cover too much. Also the zoom should be better placed in the app."
