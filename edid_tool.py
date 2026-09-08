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

# The first 8 bytes of every EDID are this fixed magic pattern -- used to
# sanity-check that a file is actually an EDID before trusting its layout.
EDID_HEADER = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
SERIAL_OFFSET = 12
CHECKSUM_OFFSET = 127
BLOCK_SIZE = 128


def load(path):
    """
    Read an EDID file from disk and validate its basic structure.

    Intent: every other function in this module assumes it's operating on
    a well-formed EDID (correct header, length a multiple of the 128-byte
    block size). Centralizing that check here means callers can't
    accidentally skip it.

    Returns the raw bytes on success; raises ValueError with a message
    identifying the file if it doesn't look like a valid EDID.
    """
    with open(path, "rb") as f:
        data = f.read()
    # An EDID is always a whole number of 128-byte blocks (1 base block
    # plus 0+ extension blocks) -- anything else means truncated/corrupt
    # data, not a real EDID.
    if len(data) < BLOCK_SIZE or len(data) % BLOCK_SIZE != 0:
        raise ValueError(f"{path}: {len(data)} bytes is not a multiple of {BLOCK_SIZE}")
    if data[:8] != EDID_HEADER:
        raise ValueError(f"{path}: missing EDID header magic, not a valid EDID")
    return data


def serial_of(data):
    """
    Extract the manufacturer serial number from an EDID base block.

    Intent: this is the field this whole tool exists to change -- reading
    it back out is how we report "current serial" to the operator and how
    we detect which panels currently collide with each other.
    """
    # The serial number is a 4-byte little-endian integer at a fixed
    # offset in the base block, per the EDID 1.4 spec.
    return int.from_bytes(data[SERIAL_OFFSET:SERIAL_OFFSET + 4], "little")


def product_name(data):
    """
    Extract a human-readable product/model string from an EDID base block,
    if one is present, for display purposes only (never used in patching
    logic).

    Intent: bare serial numbers and manufacturer/product codes aren't very
    readable on their own; surfacing the panel's own descriptor text (e.g.
    "ATNA40CU09-0") makes `list`/`info` output meaningful to a human at a
    glance, and makes it obvious when two connectors are literally the
    same panel model.

    Returns the decoded string, or None if no such descriptor is present.
    """
    # Descriptor blocks live at bytes 54, 72, 90, 108 (18 bytes each).
    # A monitor descriptor has 0x00 0x00 0x00 in bytes 0-2 and a tag in
    # byte 3: 0xFC = Display Product Name, 0xFE = unspecified ASCII text
    # (often a part number, as on this panel), 0xFF = serial as ASCII.
    # Text lives in bytes 5-17, padded with 0x0A then optionally 0x20.
    for offset in (54, 72, 90, 108):
        block = data[offset:offset + 18]
        if block[0:3] == b"\x00\x00\x00" and block[3] in (0xFC, 0xFE, 0xFF):
            # Descriptor text is padded with a trailing 0x0A (and then
            # optionally more 0x20 padding after that); split on 0x0A to
            # drop the padding rather than decoding it as garbage text.
            text = block[5:18].split(b"\x0a")[0]
            decoded = text.decode("ascii", errors="replace").strip()
            if decoded:
                return decoded
    return None


def checksum_of_block(block):
    """
    Compute whether a 128-byte EDID block's checksum is currently valid.

    Intent: a valid EDID block's 128 bytes (including its own checksum
    byte) always sum to 0 mod 256. Summing the whole block including the
    checksum byte and checking for 0 is a quick correctness check, used
    to confirm our own patched output is well-formed.
    """
    return sum(block) % 256


def recompute_checksum(block):
    """
    Compute the checksum byte that makes a 128-byte EDID block valid.

    Intent: whenever we change any byte in the base block (here, the
    serial number), the existing checksum byte is no longer correct and
    must be recalculated, or the OS/driver may reject the EDID as
    corrupt.

    `block`'s checksum byte (index CHECKSUM_OFFSET) is ignored/expected
    to already be excluded by the caller; this returns the single byte
    value (0-255) that should be stored there.
    """
    # Sum every byte except the checksum slot itself, then pick the value
    # that brings the total sum of all 128 bytes to a multiple of 256 --
    # i.e. the two's-complement-style "sum to zero mod 256" checksum the
    # EDID spec requires.
    total = sum(block[:CHECKSUM_OFFSET])
    return (256 - (total % 256)) % 256


def info(path):
    """
    Print a JSON summary of an EDID file's key fields to stdout.

    Intent: this is the read-only inspection entry point used by
    fix-edid.sh/verify-edid.sh (via subprocess) to display current state
    to the operator, and by the test suite to assert on patched output --
    JSON keeps it easy for both bash and other tooling to consume.
    """
    data = load(path)
    base = data[:BLOCK_SIZE]
    result = {
        "path": path,
        "size": len(data),
        # Total blocks minus the one mandatory base block = extension
        # block count (e.g. a CTA-861 timing extension).
        "extension_blocks": len(data) // BLOCK_SIZE - 1,
        "serial": serial_of(base),
        "product_name": product_name(base),
        "checksum_valid": checksum_of_block(base) == 0,
    }
    print(json.dumps(result, indent=2))


def patch(in_path, out_path, new_serial):
    """
    Write a copy of an EDID file with its serial number replaced and its
    checksum recomputed, leaving every other byte (including any
    extension blocks) untouched.

    Intent: this is the core operation the whole project exists to
    perform -- reproducibly and minimally changing just enough of the
    EDID to make two otherwise-identical panels distinguishable to the
    OS, without altering anything about how the panel actually behaves
    (resolution, timings, etc.).
    """
    data = bytearray(load(in_path))
    base = data[:BLOCK_SIZE]
    base[SERIAL_OFFSET:SERIAL_OFFSET + 4] = int(new_serial).to_bytes(4, "little")
    # Zero the checksum byte before recomputing so it doesn't contribute
    # its own (now-stale) value to the sum being calculated.
    base[CHECKSUM_OFFSET] = 0
    base[CHECKSUM_OFFSET] = recompute_checksum(base)
    data[:BLOCK_SIZE] = base
    with open(out_path, "wb") as f:
        f.write(data)
    # Echo the result back so the caller (bash script or a human running
    # this directly) can immediately see the new serial and confirm the
    # checksum came out valid, without a separate `info` call.
    info(out_path)


def main():
    """
    Command-line entry point: dispatches to `info` or `patch` based on
    argv, matching the two operations fix-edid.sh/verify-edid.sh need
    from this module.

    Intent: keep this tool usable both as a library (imported) and
    directly from the shell scripts via subprocess, with a minimal,
    dependency-free argument parser (no argparse) since only two fixed
    call shapes are ever needed.
    """
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
