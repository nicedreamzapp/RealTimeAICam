# Realistic documents a blind user might point the reader at. Rendered with a
# little tilt and grain so Vision reads them the way it reads a photo.
import random
from PIL import Image, ImageDraw, ImageFont, ImageFilter
R = "/System/Library/Fonts/Supplemental/Arial.ttf"
B = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
C = "/System/Library/Fonts/Supplemental/Courier New.ttf"
D = {
"usps_label": (R, """USPS GROUND ADVANTAGE
DIVINE TRIBE
PO BOX 1234
ARCATA CA 95521
SHIP TO:
JANE DOE
4821 OCEAN VIEW BLVD APT 12
SAN DIEGO CA 92107-3304
USPS TRACKING # EP
9400 1118 9922 3344 5566 77"""),
"ups_label": (B, """UPS GROUND
TRACKING #: 1Z 999 AA1 01 2345 6784
SHIP TO: ROBERT KING
77 W 45TH ST FL 3
NEW YORK NY 10036
REF: INV-2026-00451"""),
"fedex_label": (R, """FedEx Express
TRK# 7712 3456 7890
Deliver by: Fri 09/19
2230 Hillside Ave, Ste 110
Walnut Creek, CA 94596"""),
"utility_bill": (R, """Pacific Gas and Electric
Account Number: 4491027735-6
Service For: 393 Westgate Dr
Statement Date: 09/02/2026
Amount Due: $142.87
Due Date: 09/23/2026
Questions? Call 1-800-743-5000"""),
"bank_statement": (R, """Coast Central Credit Union
Member Number 00482213
Checking ending in 4471
Routing Number 121141288
Beginning Balance $3,214.55
Deposits 2 totaling $1,500.00
Ending Balance $4,102.19"""),
"pharmacy": (R, """Rx# 6143902-05  CVS Pharmacy
LISINOPRIL 10 MG TABLET
TAKE 1 TABLET BY MOUTH DAILY
Qty: 30  Refills: 3
NDC 68180-0514-01
Dr. Anita Patel
Store (707) 822-4501"""),
"insurance_card": (B, """Blue Shield of California
Member ID XEH912345678
Group No. 00W41873
RxBIN 610014  RxPCN MEDDPRIME
Office Visit $25  ER $150
Member Services 1-888-256-3650"""),
"grocery_receipt": (C, """SAFEWAY STORE 1847
2 @ 3.99 BANANAS     7.98
MILK 1 GAL           4.29
EGGS 12 CT           5.49
SUBTOTAL            17.76
TAX                  0.00
TOTAL               17.76
VISA ************4471
AUTH 083144
ST# 1847 OP# 22 TE# 04 TR# 7731
09/16/26 10:42 AM"""),
"restaurant_menu": (R, """Lunch Specials 11 AM - 3 PM
Burger and Fries 14.50
Fish Tacos (3) 16
Clam Chowder 8 oz $7 / 16 oz $12
Est. 1978"""),
"wifi_card": (R, """Guest WiFi
Network: Seaside_Guest
Password: tide2026wave
Router S/N 2K4J9X71QP"""),
"product_box": (R, """Model TUG-2.0
UPC 0 12345 67890 5
SN: A7B9C2D4E1F3G5H6J8K0
Made in China
Input 5V 2A  1500mAh"""),
"boarding_pass": (B, """ALASKA AIRLINES
Flight AS 1523 SFO to SEA
Gate B12  Seat 14C
Boards 6:45 PM  Sep 23
Confirmation C6GEGZ
Ticket 0272158843190"""),
"parking_ticket": (R, """NOTICE OF PARKING VIOLATION
Citation No. 802214557
Plate 8ABC123  CA
Violation CVC 22500(e)
Fine $65.00  Pay by 10/16/2026
Hwy 101 at 5th St, Eureka"""),
"letter": (R, """September 16, 2026
Dear Mr. Macosko,
Your claim 27776183 was received on 9/12.
Please call us at 800.555.0199 ext. 204
or write to 1600 Pennsylvania Ave NW,
Washington, DC 20500.
Sincerely, Dr. Karen Mills"""),
"nutrition": (R, """Nutrition Facts
Serving size 1 cup (240mL)
Calories 150
Total Fat 8g 10%
Sodium 120mg 5%
Vitamin D 2mcg 10%"""),
"street_sign": (B, """N MAIN ST
1200
EXIT 42  US-101 NORTH
Speed Limit 35"""),
"credit_card": (R, """4111 1111 1111 1111
VALID THRU 04/28
MATTHEW MACOSKO"""),
"tax_form": (R, """Form W-2 Wage and Tax Statement 2025
Employer ID (EIN) 94-3217765
Employee SSN XXX-XX-6789
Wages, tips 1 $52,340.18
Control number 000123"""),
}
random.seed(4)
for k, (font, t) in D.items():
    f = ImageFont.truetype(font, 40)
    lines = t.split("\n")
    im = Image.new("RGB", (1300, 80 + 62 * len(lines)), (250, 248, 240))
    ImageDraw.Draw(im).multiline_text((40, 40), t, fill=(20, 20, 25), font=f, spacing=20)
    im = im.rotate(random.uniform(-2, 2), expand=True, fillcolor=(90, 90, 90)).filter(ImageFilter.GaussianBlur(0.7))
    im.save(f"docs/{k}.jpg", quality=80)
