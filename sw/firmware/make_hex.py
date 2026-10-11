import sys

with open(sys.argv[1], 'rb') as f:
    data = f.read()

words = []
for i in range(0, len(data), 4):
    chunk = data[i:i+4]
    if len(chunk) < 4:
        chunk = chunk.ljust(4, b'\x00')
    val = chunk[0] | (chunk[1] << 8) | (chunk[2] << 16) | (chunk[3] << 24)
    words.append(f"{val:08x}")

with open(sys.argv[2], 'w') as f:
    for w in words:
        f.write(w + '\n')
print(f"Generated {len(words)} hex words.")
