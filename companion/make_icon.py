"""Draws the app icon (gold rounded badge with a red lightning bolt) as icon-source.png using only the
standard library. Run: python -I make_icon.py   then   npx tauri icon icon-source.png"""
import struct, zlib, os

S = 512

def inside_bolt(x, y):
    # lightning bolt polygon (in a 512 box)
    pts = [(300, 70), (150, 290), (250, 290), (205, 445), (365, 205), (262, 205), (320, 70)]
    n, c = len(pts), False
    j = n - 1
    for i in range(n):
        xi, yi = pts[i]; xj, yj = pts[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            c = not c
        j = i
    return c

def inside_rounded(x, y, pad, r):
    lo, hi = pad, S - pad
    if x < lo or x >= hi or y < lo or y >= hi:
        return False
    cx = min(max(x, lo + r), hi - r)
    cy = min(max(y, lo + r), hi - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

rows = []
for y in range(S):
    row = bytearray([0])
    for x in range(S):
        if inside_rounded(x, y, 24, 110):
            if inside_bolt(x, y):
                px = (230, 50, 50, 255)
            elif inside_rounded(x, y, 52, 84):
                px = (255, 200, 61, 255)
            else:
                px = (30, 32, 44, 255)
        else:
            px = (0, 0, 0, 0)
        row += bytes(px)
    rows.append(bytes(row))

def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)

png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', S, S, 8, 6, 0, 0, 0)) \
    + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'icon-source.png')
open(out, 'wb').write(png)
print('wrote', out)
