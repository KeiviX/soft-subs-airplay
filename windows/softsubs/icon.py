"""Draws the Soft Subs icon (a captions bubble on the app's gradient) for the tray and the .ico file."""

from PIL import Image, ImageDraw


def draw_icon(size: int) -> Image.Image:
    scale = 4  # Draw large and downsample for smooth edges.
    s = size * scale
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    gradient = Image.new("RGBA", (s, s))
    top, bottom = (92, 77, 240), (31, 143, 245)
    for y in range(s):
        t = y / (s - 1)
        ImageDraw.Draw(gradient).line([(0, y), (s, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    mask = Image.new("L", (s, s), 0)
    inset = int(s * 0.04)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, s - inset, s - inset], radius=int(s * 0.22), fill=255)
    image.paste(gradient, mask=mask)

    draw = ImageDraw.Draw(image)
    left, right, upper, lower = s * 0.2, s * 0.8, s * 0.27, s * 0.66
    draw.rounded_rectangle([left, upper, right, lower], radius=int(s * 0.08), fill="white")
    draw.polygon([(s * 0.32, lower - 1), (s * 0.32, s * 0.79), (s * 0.47, lower - 1)], fill="white")
    bar = (92, 77, 240)
    line = s * 0.045
    for y, x0, x1 in ((s * 0.4, 0.3, 0.58), (s * 0.4, 0.62, 0.7), (s * 0.52, 0.3, 0.42), (s * 0.52, 0.46, 0.7)):
        draw.rounded_rectangle([s * x0, y - line, s * x1, y + line], radius=line, fill=bar)
    return image.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    import sys

    draw_icon(256).save(sys.argv[1], sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
