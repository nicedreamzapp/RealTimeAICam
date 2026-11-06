# Android money port (not done yet)

The iOS money counting on `live-cam-money` has no Android mirror. Android has no Live Cam yet (the Home button
says "coming soon"), so any money answer there is still the vision model's own guess of the total.

What a port needs:

1. **Models.** The same two Core ML models exist only as Ultralytics `.pt` files (`rtcam-money-detector/models/`).
   Export them to TFLite or LiteRT: the OBB detector at 640 and the 224 denomination classifier. Check that the
   export's output layout matches PyTorch on the same letterboxed image, because Core ML did not (8006 gave 12 boxes
   against 7). Ship them in a model pack the user downloads; nothing goes into the APK (review.md).
2. **Decode.** Port `MoneyDetector.swift`:
   - area-averaged letterbox (grey 114);
   - per-class rotated NMS at 0.7, then strip-aware bill suppression (IoU 0.4 with angles within 8 degrees and the
     centre inside, or IoU 0.7);
   - numeral votes go to the smallest box;
   - a value only when the numerals and the classifier's look agree, and the `none` veto;
   - `models/decode_cfg_v3.json` thresholds.
   Keep the pure parts unit-tested against the Swift tests' numbers.
3. **Counting.** Port `LiveMoney.steady` and the honest wording:
   - look at 2-3 frames;
   - "At least N bills" whenever the count is unsure;
   - the total only when every counted bill is named;
   - the "too many" and "camera paused" lines.
4. **Questions.** Port `LiveMoney.route` (memory only for a sure count and a money question naming a denomination),
   the receipt exclusion and the whole-word matching, in English and Spanish, with `MoneyWordsES` as Android
   strings.
5. **Reader.** The OCR veto and serial dedupe should use ML Kit Text Recognition, inside the detected boxes only.
6. **Check.** Run the same replay set (IMG_0027/0028/0029 frames and the three photos) and require zero false
   claims before shipping.
