package com.mattmacosko.realtimeaicam.narrator

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AnswerTextTest {
    @Test fun finishedAnswerIsKept() {
        assertEquals("A red mug on a table.", AnswerText.completeSentences("A red mug on a table.", hitTokenLimit = true))
        assertEquals("Is that a door?", AnswerText.completeSentences("  Is that a door?  ", hitTokenLimit = true))
        assertEquals("He said \"stop.\"", AnswerText.completeSentences("He said \"stop.\"", hitTokenLimit = true))
    }

    @Test fun cutOffAnswerEndsAtTheLastFullSentence() {
        assertEquals(
            "A kitchen with a white table. A mug sits on the left.",
            AnswerText.completeSentences("A kitchen with a white table. A mug sits on the left. Behind it there is a", hitTokenLimit = true),
        )
        assertEquals("It costs 3.50 dollars.", AnswerText.completeSentences("It costs 3.50 dollars. The due da", hitTokenLimit = true))
    }

    @Test fun noFullSentenceIsClosedWithoutADanglingWord() {
        assertEquals("A lamp next to a chair.", AnswerText.completeSentences("A lamp next to a chair", hitTokenLimit = true))
        assertEquals("A dark room with a lamp.", AnswerText.completeSentences("A dark room with a lamp and the", hitTokenLimit = true))
    }

    @Test fun finishedAnswerKeepsItsLastSentenceWithoutAPeriod() {
        // 11/04 review: the model stopped on its own, so the last line is the answer, period or not.
        assertEquals(
            "This is a bill. Amount due: \$84.20 by Nov 12",
            AnswerText.completeSentences("This is a bill. Amount due: \$84.20 by Nov 12", hitTokenLimit = false),
        )
        assertEquals("Amount due: \$84.20 by Nov 12", AnswerText.completeSentences("Amount due: \$84.20 by Nov 12", hitTokenLimit = false))
        assertEquals("A lamp next to a chair", AnswerText.completeSentences("A lamp next to a chair", hitTokenLimit = false))
    }

    @Test fun onlyAnAnswerThatHitTheTokenLimitIsCutBack() {
        val cut = "A kitchen with a white table. A mug sits on the left. Behind it there is a"
        assertEquals("A kitchen with a white table. A mug sits on the left.", AnswerText.completeSentences(cut, hitTokenLimit = true))
        assertEquals(cut, AnswerText.completeSentences(cut, hitTokenLimit = false))
    }

    @Test fun tokenLimitReadFromTheEngineStats() {
        assertTrue(NarratorEngine.hitLimit("812,9400,3100,640,120", 120))
        assertFalse(NarratorEngine.hitLimit("812,9400,3100,640,37", 120))
        assertFalse(NarratorEngine.hitLimit("", 120))
    }

    @Test fun anApologyBeforeTheRefusalIsStillARefusal() {
        // 11/04 review: "I'm sorry" counted as a described thing, so the retry never ran.
        assertTrue(AnswerText.isRefusal("I'm sorry, but I can't see anything clearly in this photo."))
        assertTrue(AnswerText.isRefusal("I’m sorry, but I cannot make out what this is."))
        assertTrue(AnswerText.isRefusal("Unfortunately, I can't tell what this is."))
        assertTrue(AnswerText.isRefusal("I'm afraid I can't see much. Sorry."))
        // An apology with something described is still kept.
        assertFalse(AnswerText.isRefusal("I'm sorry, it's dim, but there is a red mug on a table."))
    }

    @Test fun hardToSeeButDescribedIsNotARefusal() {
        assertFalse(AnswerText.isRefusal("It's too dark to see much, but there is a lamp on a table."))
        assertFalse(AnswerText.isRefusal("I can't make out details. A white door is on the right."))
        assertFalse(AnswerText.isRefusal("It's hard to see clearly, but I can make out a cat on a bed."))
    }

    @Test fun nothingDescribedIsARefusal() {
        assertTrue(AnswerText.isRefusal("I can't see anything in this photo. Please retake it."))
        assertTrue(AnswerText.isRefusal("The image is too dark to make out any details."))
        assertTrue(AnswerText.isRefusal("Sorry, I cannot tell what this is. Try holding the phone steady."))
        assertTrue(AnswerText.isRefusal(""))
    }

    @Test fun retriesOnlyWhenTheyFitTheBudget() {
        // A ~10 s phone keeps every pass; the Cricket at ~110 s a pass gets none.
        assertTrue(AnswerText.retryFits(10.0, 10.0))
        assertTrue(AnswerText.retryFits(30.0, 10.0))
        assertFalse(AnswerText.retryFits(110.0, 110.0))
        assertFalse(AnswerText.retryFits(40.0, 10.0))
        assertFalse(AnswerText.retryFits(0.0, 0.0))
    }

    @Test fun nounListDropsClausesAboutThePhoto() {
        // The 456 s answer on 2026-11-04 ended "...I think I can make out it's just a blurry."
        assertNull(AnswerText.thingsOnly("it's just a blurry, dark image"))
        assertEquals("lamp, table and door", AnswerText.thingsOnly("lamp, table, the image is dark, door"))
        assertEquals("a mug", AnswerText.thingsOnly("I can see a mug, hold the camera steady"))
    }

    @Test fun dimShotsAreBrightenedFirst() {
        assertNull(AnswerText.brightenFactor(120.0))
        assertEquals(2.2f, AnswerText.brightenFactor(50.0)!!, 0.01f)
        assertEquals(2.4f, AnswerText.brightenFactor(10.0)!!, 0.01f)
    }

    @Test fun excusesAreStripped() {
        assertEquals("A blue chair by a window.", AnswerText.strippingExcuses("I can't see well. A blue chair by a window."))
        assertEquals(AnswerText.HARD_TO_SEE, AnswerText.strippingExcuses("I cannot see anything."))
    }
}
