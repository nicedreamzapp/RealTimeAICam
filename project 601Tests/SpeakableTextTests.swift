@testable import RealTime_Ai_Cam
import Testing

// Cases from the reader's real mistakes (2026-09-16): "Westgate doctor",
// phone numbers read as one big number, card numbers read in full.
struct SpeakableTextTests {
    @Test func streetAddressSaysDriveAndHouseNumberLikeAPerson() {
        #expect(SpeakableText.make("Matt Macosko\n393 Westgate Dr\nEureka, CA 95501")
            == "Matt Macosko, three ninety-three Westgate Drive, Eureka, C A, nine five five zero one")
        #expect(SpeakableText.make("1205 N Main St. Suite 200")
            == "twelve oh five North Main Street Suite two hundred")
    }

    @Test func doctorStaysADoctor() {
        #expect(SpeakableText.make("Dr. Lee, Family Medicine").hasPrefix("Dr. Lee"))
    }

    @Test func phoneNumbersAreSaidDigitByDigit() {
        #expect(SpeakableText.make("Cell 805-895-8967")
            == "Cell eight zero five, eight nine five, eight nine six seven")
        #expect(SpeakableText.make("(707) 555-0142")
            == "seven zero seven, five five five, zero one four two")
        #expect(SpeakableText.make("1-800-555-1234")
            == "one, eight zero zero, five five five, one two three four")
    }

    @Test func digitsAreSaidOneByOneUpToSixteenThenSkipped() {
        #expect(SpeakableText.make("4111 1111 1111 1111")
            == "four one one one, one one one one, one one one one, one one one one")
        #expect(SpeakableText.make("USPS TRACKING # 9400 1118 9922 3344 5566 77")
            == "USPS TRACKING number long number")
        #expect(SpeakableText.make("TRACKING #: 1Z 999 AA1 01 2345 6784")
            == "TRACKING number: long number")
        #expect(SpeakableText.make("SN: A7B9C2D4E1F3G5H6J8K0") == "SN: long number")
        #expect(SpeakableText.make("Account Number: 4491027735-6")
            == "Account Number: four four nine one zero two seven seven three five, six")
        #expect(SpeakableText.make("Citation No. 802214557")
            == "Citation number eight zero two two one four five five seven")
    }

    @Test func idNumbersAreDigitsButMoneyIsLeftAlone() {
        #expect(SpeakableText.make("Order #203041 Total $24.99")
            == "Order number two zero three zero four one Total $24.99")
        #expect(SpeakableText.make("Population 12,000") == "Population 12,000")
        #expect(SpeakableText.make("Since 1998") == "Since 1998")
        #expect(SpeakableText.make("Due Date: 09/23/2026 Amount Due: $142.87")
            == "Due Date: 09/23/2026 Amount Due: $142.87")
        #expect(SpeakableText.make("Qty 2 12 50") == "Qty 2 12 50")
        #expect(SpeakableText.make("Sodium 120mg 5%") == "Sodium 120mg 5%")
    }

    @Test func labeledShortNumbersArePairedAndMasksAreSkipped() {
        #expect(SpeakableText.make("SAFEWAY STORE 1847") == "SAFEWAY STORE eighteen forty-seven")
        #expect(SpeakableText.make("Flight AS 1523") == "Flight AS fifteen twenty-three")
        #expect(SpeakableText.make("VISA ************4471") == "VISA ending in four four seven one")
        #expect(SpeakableText.make("SSN XXX-XX-6789") == "SSN ending in six seven eight nine")
        #expect(SpeakableText.make("Checking ending in 4471") == "Checking ending in four four seven one")
    }

    @Test func codesAreSpelledButWordsAndRoadsAreNot() {
        #expect(SpeakableText.make("REF: INV-2026-00451")
            == "REF: I N V, two zero two six, zero zero four five one")
        #expect(SpeakableText.make("Plate 8ABC123") == "Plate eight A B C one two three")
        #expect(SpeakableText.make("EXIT 42 US-101 NORTH N95 B12") == "EXIT 42 US-101 NORTH N95 B12")
    }

    @Test func spanishModeAmountsAndPhones() {
        #expect(SpeakableText.make("Total to pay: 1.234,56 €") == "Total to pay: 1,234.56 €")
        #expect(SpeakableText.make("Population: 1.500.000") == "Population: 1,500,000")
        #expect(SpeakableText.make("Tel: +52 55 1234 5678")
            == "Tel: plus five two, five five, one two three four, five six seven eight")
        #expect(SpeakableText.make("Store 0147") == "Store zero one four seven")
        #expect(SpeakableText.make("Bill No. 004512") == "Bill number zero zero four five one two")
    }

    @Test func formattingAndSymbolsAreNotReadOut() {
        #expect(SpeakableText.make("**Due:** $142.87 📬") == "Due: $142.87")
        #expect(SpeakableText.make("## Your Bill\n- Amount due: $142.87")
            == "Your Bill, Amount due: $142.87")
        #expect(SpeakableText.make("Visit https://ineedhemp.com/how-to-clean/ today")
            == "Visit ineedhemp.com link today")
        #expect(SpeakableText.make("Burger and Fries.............14.50") == "Burger and Fries, 14.50")
        #expect(SpeakableText.make("Take 1/2 tablet, 1 1/2 cups") == "Take one half tablet, 1 and a half cups")
        #expect(SpeakableText.make("Pages 3-5, open 24/7, 2 x 3.99") == "Pages 3-5, open 24/7, 2 x 3.99")
    }

    @Test func expiryDatesAndHours() {
        #expect(SpeakableText.make("VALID THRU 04/28") == "VALID THRU April 2028")
        #expect(SpeakableText.make("Caducidad: 09/2027") == "Caducidad: September 2027")
        #expect(SpeakableText.make("9:00 to 18:00 Hrs") == "9:00 to 18:00")
        #expect(SpeakableText.make("Due 04/28") == "Due 04/28")
    }
}
