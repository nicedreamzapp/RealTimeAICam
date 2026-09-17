from PIL import Image, ImageDraw, ImageFont
f = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 44)
S = {
 "envelope": "Matt Macosko\n393 Westgate Dr\nEureka, CA 95501",
 "business_card": "Jane Smith, Realtor\nCell 805-895-8967\nOffice (707) 555-0142\nToll free 1-800-555-1234",
 "credit_card": "4111 1111 1111 1111\nVALID THRU 04/28",
 "tracking": "USPS TRACKING #\n9400 1118 9922 3344 5566 77",
 "store_sign": "Open 9 AM to 5 PM\n1205 N Main St. Suite 200\nCall 707.555.0199",
 "receipt": "Order #203041\nTotal $24.99\nAcct 88213456",
 "doctor": "Dr. Lee, Family Medicine\n120 Harris St, Apt 4B\nPO Box 1234",
}
for k, t in S.items():
    im = Image.new("RGB", (1100, 90 + 70 * t.count("\n")), "white")
    ImageDraw.Draw(im).multiline_text((30, 30), t, fill="black", font=f, spacing=24)
    im.save(f"samples/{k}.png")
