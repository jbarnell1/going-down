"""The four faces Crew 23 drew on their seat masks: the same four on the Reactor's floor and in the recovered tape.

Run from the repository root (Pillow): python assets_src/station/draw_faces.py
Writes godot/assets/station/faces/seat-1.png to seat-4.png (192 x 144: drawn on a 48 x 36 grid in pale marker on
a dark screen, scaled up by whole pixels so the lines stay hard). client/station_faces.gd reads them.
First drawn on 18 Nov for the recovered tape; unchanged here.
"""
from pathlib import Path
from PIL import Image, ImageDraw

out = Path(__file__).resolve().parents[2] / "godot" / "assets" / "station" / "faces"
out.mkdir(parents=True, exist_ok=True)


def draw_face(seat):
    image = Image.new("RGB", (48, 36), (30, 39, 35))
    pen = ImageDraw.Draw(image)
    ink = (215, 228, 179)

    def line(points, width=2):
        pen.line(points, fill=ink, width=width, joint="curve")

    if seat == 1:
        line([(8, 11), (16, 9), (16, 13)])
        line([(29, 10), (35, 11), (39, 9)])
        line([(11, 23), (18, 27), (32, 25), (37, 20)])
        line([(14, 27), (12, 30)], 1)
    elif seat == 2:
        pen.ellipse((7, 7, 18, 19), outline=ink, width=3)
        pen.ellipse((29, 7, 39, 19), outline=ink, width=2)
        line([(19, 26), (24, 22), (30, 27)])
    elif seat == 3:
        for x, y in [(9, 11), (28, 10)]:
            line([(x, y - 3), (x + 8, y + 6)])
            line([(x + 8, y - 3), (x, y + 5)])
        line([(10, 25), (35, 24)])
        for x in (16, 22, 28):
            line([(x, 22), (x, 27)], 1)
    else:
        line([(8, 14), (14, 9), (19, 14)])
        line([(28, 13), (33, 9), (38, 13)])
        line([(11, 21), (18, 25), (25, 26), (33, 23), (37, 18)])
        line([(31, 26), (31, 30), (27, 29)])
    image.resize((192, 144), Image.Resampling.NEAREST).save(out / f"seat-{seat}.png")


for i in range(1, 5):
    draw_face(i)
print("wrote", out)
