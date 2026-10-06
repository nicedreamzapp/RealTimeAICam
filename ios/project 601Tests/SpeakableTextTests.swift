@testable import RealTime_Ai_Cam
import Testing

// Same inputs and expected outputs as Android's SpeakableTextTest.kt, so both
// phones say the same thing. Cases from the reader's real mistakes
// (2026-09-16): "Westgate doctor", phone numbers read as one big number, card
// numbers read in full.
struct SpeakableTextTests {
    private func say(_ s: String) -> String { SpeakableText.make(s) }

    @Test func streetAddressSaysDriveAndHouseNumberLikeAPerson() {
        #expect(say("Matt Macosko\n393 Westgate Dr\nEureka, CA 95501")
            == "Matt Macosko, three ninety-three Westgate Drive, Eureka, C A, nine five five zero one")
        #expect(say("1205 N Main St. Suite 200")
            == "twelve oh five North Main Street Suite two hundred")
    }

    @Test func doctorStaysADoctor() {
        #expect(say("Dr. Lee, Family Medicine").hasPrefix("Dr. Lee"))
    }

    @Test func phoneNumbersAreSaidDigitByDigit() {
        #expect(say("Cell 805-895-8967") == "Cell eight zero five, eight nine five, eight nine six seven")
        #expect(say("(707) 555-0142") == "seven zero seven, five five five, zero one four two")
        #expect(say("1-800-555-1234") == "one, eight zero zero, five five five, one two three four")
    }

    @Test func digitsAreSaidOneByOneUpToSixteenThenSkipped() {
        #expect(say("4111 1111 1111 1111")
            == "four one one one, one one one one, one one one one, one one one one")
        #expect(say("USPS TRACKING # 9400 1118 9922 3344 5566 77") == "USPS TRACKING number long number")
        #expect(say("TRACKING #: 1Z 999 AA1 01 2345 6784") == "TRACKING number: long number")
        #expect(say("SN: A7B9C2D4E1F3G5H6J8K0") == "SN: long number")
        #expect(say("Account Number: 4491027735-6")
            == "Account Number: four four nine one zero two seven seven three five, six")
        #expect(say("Citation No. 802214557")
            == "Citation number eight zero two two one four five five seven")
    }

    @Test func idNumbersAreDigitsButMoneyIsLeftAlone() {
        #expect(say("Order #203041 Total $24.99") == "Order number two zero three zero four one Total $24.99")
        #expect(say("Population 12,000") == "Population 12,000")
        #expect(say("Since 1998") == "Since 1998")
        #expect(say("Due Date: 09/23/2026 Amount Due: $142.87") == "Due Date: 09/23/2026 Amount Due: $142.87")
        #expect(say("Qty 2 12 50") == "Qty 2 12 50")
        #expect(say("Sodium 120mg 5%") == "Sodium 120mg 5%")
    }

    @Test func labeledShortNumbersArePairedAndMasksAreSkipped() {
        #expect(say("SAFEWAY STORE 1847") == "SAFEWAY STORE eighteen forty-seven")
        #expect(say("Flight AS 1523") == "Flight AS fifteen twenty-three")
        #expect(say("VISA ************4471") == "VISA ending in four four seven one")
        #expect(say("SSN XXX-XX-6789") == "SSN ending in six seven eight nine")
        #expect(say("Checking ending in 4471") == "Checking ending in four four seven one")
    }

    @Test func codesAreSpelledButWordsAndRoadsAreNot() {
        #expect(say("REF: INV-2026-00451") == "REF: I N V, two zero two six, zero zero four five one")
        #expect(say("Plate 8ABC123") == "Plate eight A B C one two three")
        #expect(say("EXIT 42 US-101 NORTH N95 B12") == "EXIT 42 US-101 NORTH N95 B12")
    }

    @Test func spanishModeAmountsAndPhones() {
        #expect(say("Total to pay: 1.234,56 €") == "Total to pay: 1,234.56 €")
        #expect(say("Population: 1.500.000") == "Population: 1,500,000")
        #expect(say("Tel: +52 55 1234 5678")
            == "Tel: plus five two, five five, one two three four, five six seven eight")
        #expect(say("Store 0147") == "Store zero one four seven")
        #expect(say("Bill No. 004512") == "Bill number zero zero four five one two")
    }

    @Test func formattingAndSymbolsAreNotReadOut() {
        #expect(say("**Due:** $142.87 📬") == "Due: $142.87")
        #expect(say("## Your Bill\n- Amount due: $142.87") == "Your Bill, Amount due: $142.87")
        #expect(say("Visit https://ineedhemp.com/how-to-clean/ today") == "Visit ineedhemp.com link today")
        #expect(say("Burger and Fries.............14.50") == "Burger and Fries, 14.50")
        #expect(say("Take 1/2 tablet, 1 1/2 cups") == "Take one half tablet, 1 and a half cups")
        #expect(say("Pages 3-5, open 24/7, 2 x 3.99") == "Pages 3-5, open 24/7, 2 x 3.99")
    }

    @Test func expiryDatesAndHours() {
        #expect(say("VALID THRU 04/28") == "VALID THRU April 2028")
        #expect(say("Caducidad: 09/2027") == "Caducidad: September 2027")
        #expect(say("9:00 to 18:00 Hrs") == "9:00 to 18:00")
        #expect(say("Due 04/28") == "Due 04/28")
    }

    @Test func emojiWithJoinersAndSkinTonesAreDropped() {
        #expect(say("Open now 👍🏽 👨‍👩‍👧 ❤️") == "Open now")
    }

    @Test func detectionClassNamesDropLabelNotes() {
        #expect(SpeakableText.className("Bat (Animal)") == "bat")
        #expect(SpeakableText.className("Organ (Musical Instrument)") == "organ")
        #expect(SpeakableText.className("Kitchen & dining room table") == "kitchen and dining room table")
        #expect(SpeakableText.className("Person") == "person")
    }

    // iOS only: the safe door every speech path uses.
    @Test func spokenNeverLosesRealText() {
        #expect(SpeakableText.spoken("") == "")
        #expect(SpeakableText.spoken("📬") == "")
        #expect(SpeakableText.spoken("Saved to your photos with that description.")
            == "Saved to your photos with that description.")
        #expect(SpeakableText.spoken("Store 1847\nOpen 9:00 to 18:00 Hrs") == "Store eighteen forty-seven, Open 9:00 to 18:00")
    }
}
