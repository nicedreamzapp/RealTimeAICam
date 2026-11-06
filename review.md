# RT Cam review rules

Follow `~/Desktop/PROJECTS/divine-tribe-hq/shared/rules/review.md` first (risk scale, failure kinds,
report format, loop limits). These are the RT Cam additions (11/04).

- **Blind first.** Our users are blind. Anything that leaves them without speech or feedback is HIGH:
  silence, a dead or swallowed tap, a countdown with no voice, an error only on screen, a missing or
  wrong VoiceOver/TalkBack label, focus lost after a sheet closes. HIGH means `/code-review high` and a
  real-phone listen (iPhone + the Cricket) before "done".
- **Every screen size.** iPhone SE, 17e, Pro Max, iPhone Duo folded AND unfolded AND a live fold
  (`~/Scripts/duo-fold/`), Android small and big, portrait and landscape. Unfolded Duo is wide even in
  portrait (951x669).
- **Your language.** Every spoken line in the picked language is read in that language's voice: a Spanish
  line in a Spanish voice, never an English one. Hand-fixed words (taza) skip the translator. Check both
  iOS and Android, since they mirror each other.
- **Downloads only after a tap.** Language packs and models download only when the user picks them.
  No change may add MB to the app download. One exception, Matt 11/06: Live Cam's money reader models
  (`ios/MoneyModels`, about 8 MB) are built into the app.
- **Live Cam is experimental.** It stays labeled Experimental on screen and in the spoken label, reuses
  the picked model and never downloads one.
- **Parity.** A fix on one platform names its mirror commit on the other, or says why it has none.
- **Privacy.** Any new mic, speech, camera or Photos use is listed in PRIVACY.md and has a purpose string.
