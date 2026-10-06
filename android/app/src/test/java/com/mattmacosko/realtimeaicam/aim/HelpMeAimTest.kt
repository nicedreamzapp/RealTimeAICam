package com.mattmacosko.realtimeaicam.aim

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

// Boxes are normalized, origin TOP-LEFT, y grows downward (HelpMeAim.kt header).
//
// These mirror the iOS suite in `project 601Tests/HelpMeAim*Tests.swift`. When a
// rule changes on one phone it must change on the other, and these are what
// catch it.

private fun box(midX: Float, midY: Float, w: Float, h: Float) =
    AimRect(midX - w / 2, midY - h / 2, w, h)

private fun close(a: AimRect, b: AimRect, eps: Float = 1e-5f): Boolean =
    abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps &&
        abs(a.width - b.width) < eps && abs(a.height - b.height) < eps

private val key = AimVocabulary.Match("key", listOf("key"), listOf(0))

class AimSubjectTest {
    @Test fun faceUsesPersonFramingPagesPageEverythingElseWhole() {
        assertEquals(AimSteering.Framing.PERSON, AimSubject.Face.framing)
        assertEquals(AimSteering.Framing.PAGE, AimSubject.Page.framing)
        assertEquals(AimSteering.Framing.WHOLE, AimSubject.Obj(key).framing)
    }

    @Test fun spokenNames() {
        assertEquals("a face", AimSubject.Face.spokenName)
        assertEquals("a picture or page", AimSubject.Page.spokenName)
        assertEquals("a key", AimSubject.Obj(key).spokenName)
        val apple = AimVocabulary.Match("apple", listOf("apple"), listOf(1))
        assertEquals("an apple", AimSubject.Obj(apple).spokenName)
    }
}

class AimRotationTest {
    @Test fun oneQuarterTurnMapsTopLeftToTopRight() {
        val b = AimRect(0f, 0f, 0.2f, 0.1f)
        assertTrue(close(AimSteering.rotateClockwise(b, 1), AimRect(0.9f, 0f, 0.1f, 0.2f)))
    }

    @Test fun fourTurnsIsIdentityAndNegativeWraps() {
        val b = AimRect(0.1f, 0.2f, 0.3f, 0.4f)
        assertTrue(close(AimSteering.rotateClockwise(b, 4), b))
        assertTrue(close(AimSteering.rotateClockwise(b, 0), b))
        assertTrue(close(AimSteering.rotateClockwise(b, -1), AimSteering.rotateClockwise(b, 3)))
    }

    @Test fun twoTurnsFlipsBothAxes() {
        val b = AimRect(0.1f, 0.2f, 0.3f, 0.4f)
        assertTrue(close(AimSteering.rotateClockwise(b, 2), AimRect(0.6f, 0.4f, 0.3f, 0.4f)))
    }

    @Test fun quarterTurnsFromLevelAngle() {
        assertEquals(0, AimSteering.quarterTurns(90f))
        assertEquals(1, AimSteering.quarterTurns(180f))
        assertEquals(3, AimSteering.quarterTurns(0f))
    }
}

class AimSteeringTest {
    @Test fun nothingFoundWhenThereIsNoBox() {
        assertEquals(AimInstruction.NOT_FOUND, AimSteering.instruction(null, AimSteering.Framing.WHOLE))
        assertEquals(
            AimInstruction.NOT_FOUND,
            AimSteering.instruction(AimRect(0.4f, 0.4f, 0f, 0f), AimSteering.Framing.WHOLE),
        )
    }

    @Test fun centeredObjectIsFramed() {
        val b = box(0.5f, 0.5f, 0.3f, 0.3f)
        assertEquals(AimInstruction.FRAMED, AimSteering.instruction(b, AimSteering.Framing.WHOLE))
    }

    @Test fun objectOffToOneSideIsSteeredThatWay() {
        assertEquals(
            AimInstruction.MOVE_LEFT,
            AimSteering.instruction(box(0.1f, 0.5f, 0.1f, 0.1f), AimSteering.Framing.WHOLE),
        )
        assertEquals(
            AimInstruction.MOVE_RIGHT,
            AimSteering.instruction(box(0.9f, 0.5f, 0.1f, 0.1f), AimSteering.Framing.WHOLE),
        )
        assertEquals(
            AimInstruction.MOVE_UP,
            AimSteering.instruction(box(0.5f, 0.1f, 0.1f, 0.1f), AimSteering.Framing.WHOLE),
        )
        assertEquals(
            AimInstruction.MOVE_DOWN,
            AimSteering.instruction(box(0.5f, 0.9f, 0.1f, 0.1f), AimSteering.Framing.WHOLE),
        )
    }

    @Test fun tinyObjectAsksToMoveCloser() {
        assertEquals(
            AimInstruction.MOVE_CLOSER,
            AimSteering.instruction(box(0.5f, 0.5f, 0.05f, 0.05f), AimSteering.Framing.WHOLE),
        )
    }

    @Test fun subjectBiggerThanTheFrameSaysBackUp() {
        // Touching two or more edges: moving toward one pushes another out.
        val b = AimRect(-0.05f, -0.05f, 1.1f, 1.1f)
        assertEquals(AimInstruction.BACK_UP, AimSteering.instruction(b, AimSteering.Framing.WHOLE))
        assertEquals(AimInstruction.BACK_UP_CUT_OFF, AimSteering.instruction(b, AimSteering.Framing.PAGE))
    }

    @Test fun smallFaceBelongsInTheUpperThird() {
        // A small face sitting low in the frame belongs higher — and the way to
        // raise it IS to move the phone down, which is what the iPhone says too.
        val low = box(0.5f, 0.75f, 0.15f, 0.2f)
        assertEquals(AimInstruction.MOVE_DOWN, AimSteering.instruction(low, AimSteering.Framing.PERSON))
        val upper = box(0.5f, AimSteering.upperThird, 0.15f, 0.2f)
        assertEquals(AimInstruction.FRAMED, AimSteering.instruction(upper, AimSteering.Framing.PERSON))
    }

    @Test fun closeUpFaceBelongsInTheMiddle() {
        val b = box(0.5f, 0.5f, 0.45f, 0.45f)
        assertEquals(AimInstruction.FRAMED, AimSteering.instruction(b, AimSteering.Framing.PERSON))
        assertEquals(AimPoint(0.5f, 0.5f), AimSteering.target(b, AimSteering.Framing.PERSON))
    }

    @Test fun pageIsStricterAboutEdgesThanAnObject() {
        // Just inside the object margin but outside the page margin.
        // (Checked on the edge rule itself: a big box this far left is steered
        // to the middle anyway since Kareen, 2026-09-25.)
        val b = AimRect(0.01f, 0.3f, 0.5f, 0.4f)
        assertTrue(!AimSteering.isCutOff(b))
        assertTrue(AimSteering.isCutOff(b, AimSteering.pageEdgeMargin))
        assertEquals(AimInstruction.MOVE_LEFT, AimSteering.instruction(b, AimSteering.Framing.PAGE))
    }

    @Test fun looseZoneForgivesWhatTheTightZoneWouldNot() {
        val b = box(0.5f + AimSteering.wholeTolerance + 0.04f, 0.5f, 0.2f, 0.2f)
        assertEquals(AimInstruction.MOVE_RIGHT, AimSteering.instruction(b, AimSteering.Framing.WHOLE))
        assertEquals(
            AimInstruction.FRAMED,
            AimSteering.instruction(b, AimSteering.Framing.WHOLE, loose = true),
        )
    }
}

class AimPhrasesTest {
    @Test fun everyDirectionHasItsSentence() {
        assertEquals("move the phone left", AimPhrases.phrase(AimInstruction.MOVE_LEFT, AimSubject.Face))
        assertEquals("move the phone right", AimPhrases.phrase(AimInstruction.MOVE_RIGHT, AimSubject.Face))
        assertEquals("move the phone up", AimPhrases.phrase(AimInstruction.MOVE_UP, AimSubject.Face))
        assertEquals("move the phone down", AimPhrases.phrase(AimInstruction.MOVE_DOWN, AimSubject.Face))
        assertEquals("move closer", AimPhrases.phrase(AimInstruction.MOVE_CLOSER, AimSubject.Face))
        assertEquals("back up", AimPhrases.phrase(AimInstruction.BACK_UP, AimSubject.Face))
    }

    @Test fun framedSaysGotItAndCountsFaces() {
        assertEquals("got it, hold still", AimPhrases.phrase(AimInstruction.FRAMED, AimSubject.Face))
        assertEquals(
            "got it, three faces, hold still",
            AimPhrases.phrase(AimInstruction.FRAMED, AimSubject.Face, faceCount = 3),
        )
        // Only faces are counted.
        assertEquals(
            "got it, hold still",
            AimPhrases.phrase(AimInstruction.FRAMED, AimSubject.Obj(key), faceCount = 3),
        )
    }

    @Test fun cutOffOnlyMentionsThePageForAPage() {
        assertEquals(
            "back up, the page is cut off",
            AimPhrases.phrase(AimInstruction.BACK_UP_CUT_OFF, AimSubject.Page),
        )
        assertEquals("back up", AimPhrases.phrase(AimInstruction.BACK_UP_CUT_OFF, AimSubject.Obj(key)))
    }

    @Test fun notFoundNamesWhatItIsLookingFor() {
        assertEquals(
            "I don't see a key yet, move the phone slowly",
            AimPhrases.phrase(AimInstruction.NOT_FOUND, AimSubject.Obj(key)),
        )
    }

    @Test fun cantLookForFallsBackWhenNothingWasHeard() {
        assertEquals("I can't look for unicorn yet", AimPhrases.cantLookFor("unicorn"))
        assertEquals(AimPhrases.didntCatch, AimPhrases.cantLookFor("   "))
    }
}

class AimCoachTest {
    private fun coach(subject: AimSubject = AimSubject.Obj(key)) = AimCoach(subject)

    private fun say(actions: List<AimCoach.Action>): String? =
        (actions.firstOrNull { it is AimCoach.Action.Say } as? AimCoach.Action.Say)?.text

    @Test fun aSteeringLineIsNotSaidUntilItHasSettled() {
        val c = coach()
        val b = box(0.1f, 0.5f, 0.1f, 0.1f)
        assertNull(say(c.observe(b, now = 0.0, voiceBusy = false)))
        // Too soon: still inside the settle window.
        assertNull(say(c.observe(b, now = 0.2, voiceBusy = false)))
        assertEquals("move the phone left", say(c.observe(b, now = 0.6, voiceBusy = false)))
    }

    @Test fun nothingIsSaidWhileTheVoiceIsBusy() {
        val c = coach()
        val b = box(0.1f, 0.5f, 0.1f, 0.1f)
        c.observe(b, now = 0.0, voiceBusy = false)
        assertNull(say(c.observe(b, now = 0.6, voiceBusy = true)))
    }

    @Test fun framedLocksAndThenTheCountdownStarts() {
        val c = coach()
        val b = box(0.5f, 0.5f, 0.3f, 0.3f)
        c.observe(b, now = 0.0, voiceBusy = false)
        assertEquals("got it, hold still", say(c.observe(b, now = 0.4, voiceBusy = false)))
        assertTrue(c.isLocked)
        // Held steady long enough: countdown.
        val actions = c.observe(b, now = 1.0, voiceBusy = false)
        assertTrue(actions.contains(AimCoach.Action.StartCountdown))
        assertTrue(c.isCountingDown)
    }

    @Test fun leavingTheLooseZoneCancelsTheCountdownAndSaysLostIt() {
        val c = coach()
        val b = box(0.5f, 0.5f, 0.3f, 0.3f)
        c.observe(b, now = 0.0, voiceBusy = false)
        c.observe(b, now = 0.4, voiceBusy = false)
        c.observe(b, now = 1.0, voiceBusy = false)
        assertTrue(c.isCountingDown)
        // The median smoothing holds the old box for a moment, and leaving the
        // loose zone only counts after leaveAfter (0.7 s), so this takes a few
        // frames — same as the iPhone.
        val gone = box(0.05f, 0.5f, 0.05f, 0.05f)
        c.observe(gone, now = 1.1, voiceBusy = false)
        c.observe(gone, now = 2.0, voiceBusy = false)
        val actions = c.observe(gone, now = 2.8, voiceBusy = false)
        assertTrue(actions.contains(AimCoach.Action.CancelCountdown))
        assertEquals(AimPhrases.lostIt, say(actions))
        assertTrue(!c.isCountingDown)
    }

    @Test fun notFoundWaitsFiveSecondsBeforeSayingAnything() {
        val c = coach()
        assertNull(say(c.observe(null, now = 0.0, voiceBusy = false)))
        assertNull(say(c.observe(null, now = 3.0, voiceBusy = false)))
        assertEquals(
            "I don't see a key yet, move the phone slowly",
            say(c.observe(null, now = 5.5, voiceBusy = false)),
        )
    }

    @Test fun theElsewhereSentenceOnlyComesAfterFifteenSeconds() {
        val c = coach()
        c.observe(null, now = 0.0, voiceBusy = false)
        c.observe(null, now = 5.5, voiceBusy = false)
        val elsewhere = "I don't see a key. I can see a dog."
        // The "still looking" ladder never repeats the same sentence, and the
        // genuinely useful line arrives sooner now (Matt heard the old one six
        // times in a row).
        assertEquals(elsewhere, say(c.observe(null, now = 12.0, voiceBusy = false, elsewhere = elsewhere)))
        assertEquals(
            "still looking. try holding the phone a little further back",
            say(c.observe(null, now = 19.0, voiceBusy = false, elsewhere = elsewhere)),
        )
    }

    @Test fun aReversedDirectionHasToHoldLonger() {
        val c = coach()
        val left = box(0.1f, 0.5f, 0.1f, 0.1f)
        c.observe(left, now = 0.0, voiceBusy = false)
        assertEquals("move the phone left", say(c.observe(left, now = 0.6, voiceBusy = false)))
        val right = box(0.9f, 0.5f, 0.1f, 0.1f)
        c.observe(right, now = 0.7, voiceBusy = false)
        // The median still reads as "left" here, so the reversal only becomes
        // the candidate once the old boxes age out — then flipSettle (1.2 s)
        // applies instead of settle (0.5 s).
        assertNull(say(c.observe(right, now = 1.3, voiceBusy = false)))
        assertNull(say(c.observe(right, now = 2.1, voiceBusy = false)))
        assertEquals("move the phone right", say(c.observe(right, now = 2.6, voiceBusy = false)))
    }

    @Test fun medianOfBoxesIsUsedNotTheLatestJitter() {
        val boxes = listOf(
            AimRect(0.1f, 0.1f, 0.2f, 0.2f),
            AimRect(0.2f, 0.2f, 0.2f, 0.2f),
            AimRect(0.3f, 0.3f, 0.2f, 0.2f),
        )
        val m = AimCoach.median(boxes)!!
        assertEquals(0.2f, m.minX, 1e-5f)
        assertEquals(0.2f, m.minY, 1e-5f)
    }
}

class AimBurstTest {
    @Test fun theBestFramedShotWins() {
        val frames = listOf(
            AimBurst.Frame(box(0.2f, 0.5f, 0.2f, 0.2f), 300.0),
            AimBurst.Frame(box(0.5f, 0.5f, 0.2f, 0.2f), 300.0),
            AimBurst.Frame(box(0.8f, 0.5f, 0.2f, 0.2f), 300.0),
        )
        assertEquals(1, AimBurst.pick(frames, AimSteering.Framing.WHOLE))
    }

    @Test fun aBlurryFramedShotLosesToASharpOne() {
        val frames = listOf(
            AimBurst.Frame(box(0.5f, 0.5f, 0.2f, 0.2f), 100.0),
            AimBurst.Frame(box(0.5f, 0.5f, 0.2f, 0.2f), 2000.0),
        )
        assertEquals(1, AimBurst.pick(frames, AimSteering.Framing.WHOLE))
    }

    @Test fun withNoSubjectAnywhereTheSharpestIsKept() {
        val frames = listOf(
            AimBurst.Frame(null, 10.0),
            AimBurst.Frame(null, 900.0),
            AimBurst.Frame(null, 50.0),
        )
        assertEquals(1, AimBurst.pick(frames, AimSteering.Framing.WHOLE))
    }

    @Test fun emptyBurstPicksNothing() {
        assertNull(AimBurst.pick(emptyList(), AimSteering.Framing.WHOLE))
    }

    @Test fun aCutOffSubjectIsNeverCropped() {
        val b = AimRect(0f, 0.3f, 0.3f, 0.3f)
        assertNull(AimBurst.crop(b, 4000f, 3000f, AimSteering.Framing.WHOLE))
    }

    @Test fun aWellFramedBigSubjectIsLeftAlone() {
        val b = box(0.5f, 0.5f, 0.5f, 0.5f)
        assertNull(AimBurst.crop(b, 4000f, 3000f, AimSteering.Framing.WHOLE))
    }

    @Test fun aSmallOffCenterSubjectIsCroppedAndStaysInside() {
        val b = box(0.3f, 0.4f, 0.15f, 0.15f)
        val crop = AimBurst.crop(b, 4000f, 3000f, AimSteering.Framing.WHOLE)
        assertNotNull(crop)
        val r = crop!!
        val subject = AimRect(b.minX * 4000f, b.minY * 3000f, b.width * 4000f, b.height * 3000f)
        assertTrue(r.minX <= subject.minX + 1f && r.maxX >= subject.maxX - 1f)
        assertTrue(r.minY <= subject.minY + 1f && r.maxY >= subject.maxY - 1f)
        assertTrue(r.minX >= 0f && r.minY >= 0f && r.maxX <= 4000f && r.maxY <= 3000f)
    }

    @Test fun aSmallPhotoIsNeverCropped() {
        val b = box(0.3f, 0.4f, 0.15f, 0.15f)
        assertNull(AimBurst.crop(b, 800f, 600f, AimSteering.Framing.WHOLE))
    }
}

class AimPageTest {
    @Test fun theDocumentFinderWinsWhenItIsSure() {
        val doc = AimRect(0.1f, 0.1f, 0.5f, 0.5f)
        val other = AimPage.Candidate(AimRect(0.6f, 0.6f, 0.3f, 0.3f), documentLike = true)
        assertEquals(doc, AimPage.choose(doc, listOf(other), null))
    }

    @Test fun aColourfulRectangleIsNotAPage() {
        assertTrue(AimPage.isDocumentLike(0.9f, 0.9f, 0.88f))
        assertTrue(!AimPage.isDocumentLike(0.9f, 0.2f, 0.1f))
        assertTrue(!AimPage.isDocumentLike(0.1f, 0.1f, 0.1f))
    }

    @Test fun onlySupportedRectanglesAreConsidered() {
        val backup = AimRect(0.1f, 0.1f, 0.4f, 0.4f)
        val unsupported = AimPage.Candidate(AimRect(0.7f, 0.7f, 0.2f, 0.2f), documentLike = false)
        assertEquals(backup, AimPage.choose(null, listOf(unsupported), backup))
    }

    @Test fun theModelsBiggerBoxWinsForAPageRunningOffTheEdge() {
        val small = AimPage.Candidate(AimRect(0.2f, 0.2f, 0.3f, 0.3f), documentLike = true)
        val big = AimRect(0.1f, 0.1f, 0.6f, 0.6f)
        assertEquals(big, AimPage.choose(null, listOf(small), big))
    }
}

class AimHoldTest {
    @Test fun aPhoneLyingFlatIsStillPortrait() {
        assertEquals(90f, AimHold.captureAngle(0f, Triple(0.0, 0.0, -1.0)), 1e-5f)
    }

    @Test fun onlyAClearSidewaysHoldIsLandscape() {
        assertTrue(AimHold.isClearlyLandscape(x = 0.95, y = 0.1, z = 0.1))
        assertTrue(!AimHold.isClearlyLandscape(x = 0.5, y = 0.5, z = 0.1))
        assertEquals(0f, AimHold.captureAngle(0f, Triple(0.95, 0.1, 0.1)), 1e-5f)
    }

    @Test fun unknownGravityIsPortrait() {
        assertEquals(90f, AimHold.captureAngle(0f, null), 1e-5f)
        assertEquals(90f, AimHold.captureAngle(null, Triple(0.95, 0.1, 0.1)), 1e-5f)
    }
}

class AimElsewhereTest {
    private fun seen(name: String, conf: Float = 0.9f, at: Float = 0.1f) =
        AimElsewhere.Seen(name, conf, AimRect(at, at, 0.1f, 0.1f))

    @Test fun roomsAndGenresAreNeverSaid() {
        assertNull(AimElsewhere.spokenName("home interior"))
        assertNull(AimElsewhere.spokenName("tv genre"))
        assertNull(AimElsewhere.spokenName("living room"))
        assertEquals("laptop", AimElsewhere.spokenName("laptop"))
    }

    @Test fun breedsCollapseToTheAnimalAndRolesToPerson() {
        assertEquals("dog", AimElsewhere.spokenName("samoyed"))
        assertEquals("cat", AimElsewhere.spokenName("persian cat"))
        assertEquals("person", AimElsewhere.spokenName("tattoo artist"))
        assertEquals("person", AimElsewhere.spokenName("woman"))
    }

    @Test fun needsThreeFramesAndSeventyPercent() {
        val frames = listOf(
            listOf(seen("laptop")), listOf(seen("laptop")), listOf(seen("laptop")),
            listOf(seen("mirror", conf = 0.5f)),
        )
        val picked = AimElsewhere.pick(frames, emptySet())
        assertTrue(picked.contains("laptop"))
        assertTrue(!picked.contains("mirror"))
    }

    @Test fun theTargetIsNeverOffered() {
        val frames = listOf(listOf(seen("dog")), listOf(seen("dog")), listOf(seen("dog")))
        assertTrue(AimElsewhere.pick(frames, setOf("dog")).isEmpty())
    }

    @Test fun theSentenceReadsLikeEnglish() {
        assertEquals(
            "I don't see a key. I can see a dog.",
            AimElsewhere.sentence(AimSubject.Obj(key), listOf("dog")),
        )
        assertEquals(
            "I don't see a key. I can see a dog and a laptop.",
            AimElsewhere.sentence(AimSubject.Obj(key), listOf("dog", "laptop")),
        )
        assertEquals(
            "I don't see a key. I can see a dog, a laptop and a mirror.",
            AimElsewhere.sentence(AimSubject.Obj(key), listOf("dog", "laptop", "mirror")),
        )
        assertEquals(
            "I don't see a key, and nothing else stands out. Try another direction.",
            AimElsewhere.sentence(AimSubject.Obj(key), emptyList()),
        )
    }

    @Test fun glassesTakeNoArticle() {
        assertEquals("glasses", AimElsewhere.article("glasses"))
        assertEquals("a laptop", AimElsewhere.article("laptop"))
    }
}

class AimVocabularyTest {
    private val vocab = listOf(
        "key", "dog", "cat", "samoyed", "persian cat", "cup", "mug", "laptop", "television", "couch",
    )

    @Test fun aPlainWordMatches() {
        val m = AimVocabulary.match("key", vocab)
        assertNotNull(m)
        assertEquals("key", m!!.spokenName)
    }

    @Test fun fillersAreStripped() {
        // normalize only strips the filler; the singular comes from forms().
        assertEquals("keys", AimVocabulary.normalize("I'm looking for my keys"))
        val m = AimVocabulary.match("where's my keys", vocab)
        assertEquals("key", m?.spokenName)
    }

    @Test fun pluralsBecomeSingular() {
        assertEquals("key", AimVocabulary.match("keys", vocab)?.spokenName)
    }

    @Test fun synonymsReachTheRealClass() {
        assertEquals("tv", AimVocabulary.match("tv", vocab)?.spokenName)
        assertTrue(AimVocabulary.match("tv", vocab)!!.classNames.contains("television"))
        assertTrue(AimVocabulary.match("sofa", vocab)!!.classNames.contains("couch"))
    }

    @Test fun thingBeforeAPrepositionWins() {
        assertEquals("key", AimVocabulary.match("keys to the car", vocab)?.spokenName)
    }

    @Test fun lookingForADogAlsoFindsItsBreeds() {
        val m = AimVocabulary.match("dog", vocab)
        assertNotNull(m)
        assertTrue(m!!.classNames.contains("dog"))
        assertTrue(m.classNames.contains("samoyed"))
    }

    @Test fun aWordTheModelDoesNotKnowIsRefused() {
        assertNull(AimVocabulary.match("unicorn", vocab))
    }

    @Test fun aSynonymNeverInventsAClass() {
        // "wallet" has no class in this vocabulary, so it must not match.
        assertNull(AimVocabulary.match("wallet", vocab))
    }

    @Test fun articles() {
        assertEquals("a key", AimVocabulary.withArticle("key"))
        assertEquals("an apple", AimVocabulary.withArticle("apple"))
    }
}

class AimListeningTest {
    @Test fun silenceStopsListeningAfterSomethingWasHeard() {
        assertTrue(AimListening.shouldStop(heardSomething = true, quiet = 1.4, total = 3.0))
        assertTrue(!AimListening.shouldStop(heardSomething = true, quiet = 0.5, total = 3.0))
    }

    @Test fun nothingHeardGivesUpAfterSixSeconds() {
        assertTrue(!AimListening.shouldStop(heardSomething = false, quiet = 0.0, total = 4.0))
        assertTrue(AimListening.shouldStop(heardSomething = false, quiet = 0.0, total = 6.5))
    }

    @Test fun thereIsAlwaysAHardStop() {
        assertTrue(AimListening.shouldStop(heardSomething = true, quiet = 0.0, total = 9.5))
    }

    @Test fun repliesMatchTheResult() {
        assertNull(AimListening.reply(AimListening.Result.Heard("key")))
        assertEquals(AimPhrases.heardNothing, AimListening.reply(AimListening.Result.Silence))
        assertEquals(AimPhrases.didntCatch, AimListening.reply(AimListening.Result.NotUnderstood))
    }
}

class AimTonesTest {
    @Test fun theBeepIsAValidWav() {
        val wav = AimTones.wav(AimTones.start)
        assertEquals('R'.code.toByte(), wav[0])
        assertEquals('I'.code.toByte(), wav[1])
        assertEquals('F'.code.toByte(), wav[2])
        assertEquals('F'.code.toByte(), wav[3])
        // 44 byte header plus 2 bytes per sample.
        val expected = 44 + (AimTones.sampleRate * AimTones.noteSeconds).toInt() * AimTones.start.size * 2
        assertEquals(expected, wav.size)
    }
}
