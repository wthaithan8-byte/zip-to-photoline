from PIL import Image, ImageDraw, ImageFont

W, H = 1024, 500
img = Image.new("RGB", (W, H))
draw = ImageDraw.Draw(img)

# Gradient background matching the app icon (blue -> green, diagonal)
top_left = (37, 99, 200)     # blue
bottom_right = (29, 191, 122)  # green
for y in range(H):
    for_x_ratio = y / H
    r = int(top_left[0] + (bottom_right[0] - top_left[0]) * for_x_ratio)
    g = int(top_left[1] + (bottom_right[1] - top_left[1]) * for_x_ratio)
    b = int(top_left[2] + (bottom_right[2] - top_left[2]) * for_x_ratio)
    draw.line([(0, y), (W, y)], fill=(r, g, b))

# Paste app icon on the left, rounded corners (source icon has an opaque
# square background meant for OS-level adaptive-icon masking, not transparency)
icon = Image.open("assets/icon/icon.png").convert("RGBA")
icon_size = 340
icon = icon.resize((icon_size, icon_size), Image.LANCZOS)

mask = Image.new("L", (icon_size, icon_size), 0)
mask_draw = ImageDraw.Draw(mask)
mask_draw.rounded_rectangle([(0, 0), (icon_size, icon_size)], radius=icon_size // 5, fill=255)

icon_x, icon_y = 70, (H - icon_size) // 2
img.paste(icon, (icon_x, icon_y), mask)

# Text on the right
title_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/SukhumvitSet.ttc", 64)
subtitle_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/SukhumvitSet.ttc", 30)

text_x = icon_x + icon_size + 50
draw.text((text_x, 165), "ZIP TO", font=title_font, fill="white")
draw.text((text_x, 235), "PHOTOLINE", font=title_font, fill="white")
draw.text((text_x, 320), "แตกไฟล์ ZIP เป็นรูปภาพ แชร์เข้า LINE ได้ทันที", font=subtitle_font, fill=(255, 255, 255, 230))

img.save("store/feature-graphic.png")
print("saved", img.size)
