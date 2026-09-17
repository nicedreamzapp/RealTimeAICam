# Spanish documents for the reader's Spanish-to-English mode (files start with es_).
import random
from PIL import Image, ImageDraw, ImageFont, ImageFilter
R = "/System/Library/Fonts/Supplemental/Arial.ttf"
D = {
"es_factura": """FACTURA No. 004512
Fecha: 16/09/2026
Total a pagar: 1.234,56 €
IVA 21%: 214,26 €
Cuenta IBAN ES91 2100 0418 4502 0005 1332""",
"es_direccion_mx": """Av. Reforma 222, Piso 5
Col. Juárez, C.P. 06600
Ciudad de México, CDMX
Tel. 55 1234 5678""",
"es_direccion_es": """Calle Mayor 15, 3º B
28013 Madrid
Teléfono: +34 912 345 678""",
"es_farmacia": """Paracetamol 500 mg
Tomar 1 tableta cada 8 horas
Lote: AB12345
Caducidad: 09/2027
Receta No. 887612""",
"es_recibo": """SUPERMERCADO LA PLAZA
Tienda 0147
Leche 1 L  $24.50
Pan dulce  $18.00
TOTAL  $42.50
Tarjeta ****4471
Folio 99812345""",
"es_letrero": """Horario: Lunes a Viernes
9:00 a 18:00 hrs
Estacionamiento $15 por hora
Salida 42  Carretera 101""",
"es_envio": """Número de guía:
9400 1118 9922 3344 5566 77
Destinatario: María López
Calle 5 de Mayo 123, Int. 4
C.P. 44100, Guadalajara, Jal.""",
"es_medico": """Dr. José Ramírez
Consultorio 204
Cita: 23 de septiembre, 10:30
Población: 1.500.000 habitantes
Receta 1/2 tableta""",
}
random.seed(7)
for k, t in D.items():
    f = ImageFont.truetype(R, 40)
    lines = t.split("\n")
    im = Image.new("RGB", (1300, 80 + 62 * len(lines)), (250, 248, 240))
    ImageDraw.Draw(im).multiline_text((40, 40), t, fill=(20, 20, 25), font=f, spacing=20)
    im = im.rotate(random.uniform(-2, 2), expand=True, fillcolor=(90, 90, 90)).filter(ImageFilter.GaussianBlur(0.7))
    im.save(f"docs/{k}.jpg", quality=80)
