#!/usr/bin/env python3
"""
EDID inspection/patching helper for zenbook-duo-touch-edid-fix.

An EDID is one or more 128-byte blocks. This tool only ever touches the
base block: bytes 12-15 are the little-endian manufacturer serial number,
and byte 127 is a checksum such that all 128 bytes of the block sum to
0 mod 256. Any extension blocks (bytes 128 onward) are left untouched,
including their own trailing checksum byte.
"""

import json
import sys

EDID_HEADER = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
SERIAL_OFFSET = 12
CHECKSUM_OFFSET = 127
BLOCK_SIZE = 128


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < BLOCK_SIZE or len(data) % BLOCK_SIZE != 0:
        raise ValueError(f"{path}: {len(data)} bytes is not a multiple of {BLOCK_SIZE}")
    if data[:8] != EDID_HEADER:
        raise ValueError(f"{path}: missing EDID header magic, not a valid EDID")
    return data


def serial_of(data):
    return int.from_bytes(data[SERIAL_OFFSET:SERIAL_OFFSET + 4], "little")


def product_name(data):
    # Descriptor blocks live at bytes 54, 72, 90, 108 (18 bytes each).
    # A monitor descriptor has 0x00 0x00 0x00 in bytes 0-2 and a tag in
    # byte 3: 0xFC = Display Product Name, 0xFE = unspecified ASCII text
    # (often a part number, as on this panel), 0xFF = serial as ASCII.
    # Text lives in bytes 5-17, padded with 0x0A then optionally 0x20.
    for offset in (54, 72, 90, 108):
        block = data[offset:offset + 18]
        if block[0:3] == b"\x00\x00\x00" and block[3] in (0xFC, 0xFE, 0xFF):
            text = block[5:18].split(b"\x0a")[0]
            decoded = text.decode("ascii", errors="replace").strip()
            if decoded:
                return decoded
    return None


def checksum_of_block(block):
    return sum(block) % 256


def recompute_checksum(block):
    # Zero the checksum byte, sum the rest, then pick the byte that
    # brings the total to 0 mod 256.
    total = sum(block[:CHECKSUM_OFFSET])
    return (256 - (total % 256)) % 256


def info(path):
    data = load(path)
    base = data[:BLOCK_SIZE]
    result = {
        "path": path,
        "size": len(data),
        "extension_blocks": len(data) // BLOCK_SIZE - 1,
        "serial": serial_of(base),
        "product_name": product_name(base),
        "checksum_valid": checksum_of_block(base) == 0,
    }
    print(json.dumps(result, indent=2))


def patch(in_path, out_path, new_serial):
    data = bytearray(load(in_path))
    base = data[:BLOCK_SIZE]
    base[SERIAL_OFFSET:SERIAL_OFFSET + 4] = int(new_serial).to_bytes(4, "little")
    base[CHECKSUM_OFFSET] = 0
    base[CHECKSUM_OFFSET] = recompute_checksum(base)
    data[:BLOCK_SIZE] = base
    with open(out_path, "wb") as f:
        f.write(data)
    info(out_path)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} info <edid-file>", file=sys.stderr)
        print(f"       {sys.argv[0]} patch <in-edid-file> <out-edid-file> <new-serial>", file=sys.stderr)
        sys.exit(2)

    cmd = sys.argv[1]
    try:
        if cmd == "info" and len(sys.argv) == 3:
            info(sys.argv[2])
        elif cmd == "patch" and len(sys.argv) == 5:
            patch(sys.argv[2], sys.argv[3], int(sys.argv[4]))
        else:
            raise ValueError("bad arguments")
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
