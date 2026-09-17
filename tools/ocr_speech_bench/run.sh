#!/bin/zsh
# run.sh IMAGE... : OCR each picture, then render what the app says NOW and what it
# would say AFTER the fix, and transcribe both with whisper so we can hear it as text.
D=${0:A:h}; OUT=$D/out; mkdir -p $OUT
[[ $D/bench -nt "$D/../../project 601/SpeakableText.swift" ]] || swiftc -O "$D/../../project 601/SpeakableText.swift" "$D/../../SpanishTranslationEngine.swift" $D/main.swift -o $D/bench || exit 1
[[ -e $D/es_final_with_rules.json.gz ]] || ln -s "$D/../../es_final_with_rules.json.gz" $D/
for img in "$@"; do
  n=${img:t:r}
  if [[ $n == es_* ]]; then
    # Spanish mode: the app OCRs in Spanish, translates line by line, speaks the English.
    raw=$($D/bench ocr-es "$img")
    joined=$(print -r -- "$raw" | tr '\n' ' ')
    # Translated line by line like LiveOCRViewModel.translationUnits; " | " marks the lines.
    appnow=$(print -rn -- "$raw" | $D/bench translate 2>&1 >/dev/null | grep '^RESULT' | cut -f2-)
    print "  spanish:   $joined"
    src=${appnow// | /$'\n'}
  else
    raw=$($D/bench ocr "$img")
    appnow=$(print -r -- "$raw" | tr '\n' ' ')          # app joins lines with a space
    src=$raw                                             # speech keeps the line breaks
  fi
  fixed=$(print -r -- "$src" | $D/bench fix)
  $D/bench say $OUT/$n.now.caf "$appnow"
  $D/bench say $OUT/$n.fix.caf "$fixed"
  print "=== $n"
  print "  read:      $appnow"
  print "  fixed txt: $fixed"
done
