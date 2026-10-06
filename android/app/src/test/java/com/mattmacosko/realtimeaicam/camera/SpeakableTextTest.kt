package com.mattmacosko.realtimeaicam.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from the iPhone's SpeakableTextTests.swift. Cases from the reader's
// real mistakes (2026-09-16): "Westgate doctor", phone numbers read as one big
// number, card numbers read in full.
class SpeakableTextTest {
    private fun say(s: String) = SpeakableText.make(s)

    @Test fun streetAddressSaysDriveAndHouseNumberLikeAPerson() {
        assertEquals(
            "Matt Macosko, three ninety-three Westgate Drive, Eureka, C A, nine five five zero one",
            say("Matt Macosko\n393 Westgate Dr\nEureka, CA 95501"),
        )
        assertEquals(
            "twelve oh five North Main Street Suite two hundred",
            say("1205 N Main St. Suite 200"),
        )
    }

    @Test fun doctorStaysADoctor() {
        assertTrue(say("Dr. Lee, Family Medicine").startsWith("Dr. Lee"))
    }

    @Test fun phoneNumbersAreSaidDigitByDigit() {
        assertEquals("Cell eight zero five, eight nine five, eight nine six seven", say("Cell 805-895-8967"))
        assertEquals("seven zero seven, five five five, zero one four two", say("(707) 555-0142"))
        assertEquals("one, eight zero zero, five five five, one two three four", say("1-800-555-1234"))
    }

    @Test fun digitsAreSaidOneByOneUpToSixteenThenSkipped() {
        assertEquals(
            "four one one one, one one one one, one one one one, one one one one",
            say("4111 1111 1111 1111"),
        )
        assertEquals("USPS TRACKING number long number", say("USPS TRACKING # 9400 1118 9922 3344 5566 77"))
        assertEquals("TRACKING number: long number", say("TRACKING #: 1Z 999 AA1 01 2345 6784"))
        assertEquals("SN: long number", say("SN: A7B9C2D4E1F3G5H6J8K0"))
        assertEquals(
            "Account Number: four four nine one zero two seven seven three five, six",
            say("Account Number: 4491027735-6"),
        )
        assertEquals(
            "Citation number eight zero two two one four five five seven",
            say("Citation No. 802214557"),
        )
    }

    @Test fun idNumbersAreDigitsButMoneyIsLeftAlone() {
        assertEquals("Order number two zero three zero four one Total \$24.99", say("Order #203041 Total \$24.99"))
        assertEquals("Population 12,000", say("Population 12,000"))
        assertEquals("Since 1998", say("Since 1998"))
        assertEquals(
            "Due Date: 09/23/2026 Amount Due: \$142.87",
            say("Due Date: 09/23/2026 Amount Due: \$142.87"),
        )
        assertEquals("Qty 2 12 50", say("Qty 2 12 50"))
        assertEquals("Sodium 120mg 5%", say("Sodium 120mg 5%"))
    }

    @Test fun labeledShortNumbersArePairedAndMasksAreSkipped() {
        assertEquals("SAFEWAY STORE eighteen forty-seven", say("SAFEWAY STORE 1847"))
        assertEquals("Flight AS fifteen twenty-three", say("Flight AS 1523"))
        assertEquals("VISA ending in four four seven one", say("VISA ************4471"))
        assertEquals("SSN ending in six seven eight nine", say("SSN XXX-XX-6789"))
        assertEquals("Checking ending in four four seven one", say("Checking ending in 4471"))
    }

    @Test fun codesAreSpelledButWordsAndRoadsAreNot() {
        assertEquals("REF: I N V, two zero two six, zero zero four five one", say("REF: INV-2026-00451"))
        assertEquals("Plate eight A B C one two three", say("Plate 8ABC123"))
        assertEquals("EXIT 42 US-101 NORTH N95 B12", say("EXIT 42 US-101 NORTH N95 B12"))
    }

    @Test fun spanishModeAmountsAndPhones() {
        assertEquals("Total to pay: 1,234.56 €", say("Total to pay: 1.234,56 €"))
        assertEquals("Population: 1,500,000", say("Population: 1.500.000"))
        assertEquals(
            "Tel: plus five two, five five, one two three four, five six seven eight",
            say("Tel: +52 55 1234 5678"),
        )
        assertEquals("Store zero one four seven", say("Store 0147"))
        assertEquals("Bill number zero zero four five one two", say("Bill No. 004512"))
    }

    @Test fun formattingAndSymbolsAreNotReadOut() {
        assertEquals("Due: \$142.87", say("**Due:** \$142.87 📬"))
        assertEquals("Your Bill, Amount due: \$142.87", say("## Your Bill\n- Amount due: \$142.87"))
        assertEquals("Visit ineedhemp.com link today", say("Visit https://ineedhemp.com/how-to-clean/ today"))
        assertEquals("Burger and Fries, 14.50", say("Burger and Fries.............14.50"))
        assertEquals("Take one half tablet, 1 and a half cups", say("Take 1/2 tablet, 1 1/2 cups"))
        assertEquals("Pages 3-5, open 24/7, 2 x 3.99", say("Pages 3-5, open 24/7, 2 x 3.99"))
    }

    @Test fun expiryDatesAndHours() {
        assertEquals("VALID THRU April 2028", say("VALID THRU 04/28"))
        assertEquals("Caducidad: September 2027", say("Caducidad: 09/2027"))
        assertEquals("9:00 to 18:00", say("9:00 to 18:00 Hrs"))
        assertEquals("Due 04/28", say("Due 04/28"))
    }

    // Android-only: ML Kit keeps line breaks, so the whole read goes straight in.
    @Test fun emojiWithJoinersAndSkinTonesAreDropped() {
        assertEquals("Open now", say("Open now 👍🏽 👨‍👩‍👧 ❤️"))
    }

    // iOS SpeechManager fix: label notes and ampersands in detection class names.
    @Test fun detectionClassNamesDropLabelNotes() {
        assertEquals("bat", SpeakableText.className("Bat (Animal)"))
        assertEquals("organ", SpeakableText.className("Organ (Musical Instrument)"))
        assertEquals("kitchen and dining room table", SpeakableText.className("Kitchen & dining room table"))
        assertEquals("person", SpeakableText.className("Person"))
    }
}
