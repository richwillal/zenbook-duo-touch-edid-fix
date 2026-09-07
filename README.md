# zenbook-duo-touch-edid-fix

Fixes touchscreen input landing on the wrong screen (or both screens) on
dual-panel laptops -- such as the ASUS Zenbook Duo -- where both displays
report byte-for-byte identical EDID data.

## The problem

On the Zenbook Duo (and likely other dual-screen devices using the same
panel on both sides), the top and bottom panels are the same physical
part, and the EDID they report over DisplayPort is *identical*, right
down to a manufacturer serial number of `0` on both. Linux's
touch-to-display matching relies on being able to tell displays apart,
so with two indistinguishable EDIDs, touch input can't be reliably
associated with the correct panel.

## The fix

Give one of the two panels a distinct serial number in its EDID, then
tell the kernel to use that modified copy instead of what the hardware
actually reports, using the kernel's built-in
[`drm.edid_firmware=`](https://docs.kernel.org/gpu/edid.html) boot
parameter. Once the two panels report different serials, touch mapping
works correctly.

This only ever changes two things in the EDID: the 4-byte serial number
field, and the checksum byte that has to be recomputed to match. Nothing
else about the panel's reported timings/capabilities changes.

## Requirements

- A GRUB-based Linux install (this script edits `/etc/default/grub` and
  runs `update-grub`)
- `python3` (used for the actual EDID byte manipulation)
- `sudo` access
- A DRM driver that honors `drm.edid_firmware=` (this is a mainline
  kernel feature, not vendor-specific -- i915, amdgpu, etc. all support it)

## Usage

```bash
git clone https://github.com/richwillal/zenbook-duo-touch-edid-fix.git
cd zenbook-duo-touch-edid-fix
```

**1. See what's connected**, and confirm which connectors are reporting
identical panel identities:

```bash
./fix-edid.sh list
```

```
Connected displays:

CONNECTOR  SERIAL     PRODUCT
eDP-1      0          ATNA40CU09-0
eDP-2      0          ATNA40CU09-0

Duplicate groups (same panel identity -- these are indistinguishable to the OS):
  - eDP-1 eDP-2
```

**2. Preview the fix** for the connector you want to change (usually the
bottom/secondary screen -- leave the primary one alone):

```bash
./fix-edid.sh fix eDP-2 --dry-run
```

This shows the new serial number it would assign (by default, one
higher than the highest serial currently seen among the duplicate
group) and exactly what it would write, without touching anything.

**3. Apply it**:

```bash
./fix-edid.sh fix eDP-2
```

You'll be asked to confirm before it writes `/lib/firmware/edid/*.bin`,
edits `GRUB_CMDLINE_LINUX` in `/etc/default/grub` (a timestamped backup
is made first), and runs `update-grub`.

**4. Reboot**, then confirm the override is actually active:

```bash
./fix-edid.sh verify eDP-2
```

### Choosing a specific serial number

```bash
./fix-edid.sh fix eDP-2 --serial 42
```

### Reverting

```bash
./fix-edid.sh revert eDP-2
```

Removes the `drm.edid_firmware=` entry for that connector from GRUB,
deletes the installed firmware file, and runs `update-grub`. Reboot to
apply.

### Verifying independently

`verify-edid.sh` is also a standalone script, so you (or anyone else) can
run just the verification check without pulling in the fixing logic:

```bash
./verify-edid.sh              # checks every drm.edid_firmware= entry found
./verify-edid.sh eDP-2        # checks only this connector
```

For each configured connector it confirms the firmware file exists, the
connector is connected, and -- the check that actually matters -- that
the connector's **live** EDID (what the kernel is using right now) is
byte-for-byte identical to the configured firmware file. Exits non-zero
if anything doesn't match, so it's safe to use in scripts.

## Testing

`edid_tool.py`'s patch logic is checked against a real, independently
hand-created fix, not just plausibility: `test/fixtures/` contains an
unmodified EDID dump from a Zenbook Duo's top panel (serial 0) and the
bottom panel's EDID as it was manually patched by hand -- byte editing
and checksum recomputation done directly, before this tool existed --
which is the actual fix currently running on that hardware.

```bash
./test/run-tests.sh
```

This patches the original fixture with the tool and asserts the result
is byte-for-byte identical to the manual fix, along with checks that
only the serial and checksum bytes ever change and that the checksum is
valid. Both fixture files are just hardware-identifying EDID data (panel
model and, post-fix, an arbitrary serial) -- nothing user-identifying.

## Troubleshooting

**`verify` shows the live EDID still has the old serial after rebooting.**
Some systems load boot-time firmware overrides before the root
filesystem (and `/lib/firmware`) is available, via the initramfs. If
that's the case here, rebuild it after installing the firmware file:

```bash
sudo update-initramfs -u
```

then reboot again.

**I have more than two panels, or non-eDP connectors, in the duplicate
group.** The tool works on any DRM connector name shown by
`./fix-edid.sh list`, not just `eDP-*` -- pick whichever one you want to
give a new identity.

## How it works

An EDID is one or more 128-byte blocks. `edid_tool.py` reads the base
block's manufacturer serial number (bytes 12-15, little-endian) and its
checksum byte (byte 127, chosen so the 128 bytes sum to 0 mod 256),
replaces the serial, recomputes the checksum, and leaves everything else
-- including any extension blocks -- untouched. `fix-edid.sh` handles
discovering connectors, picking a non-conflicting serial, installing the
result under `/lib/firmware/edid/`, and wiring it up via
`drm.edid_firmware=<connector>:edid/<file>.bin` on the kernel command
line.

## License

GPLv3, matching [zenbook-duo-linux](https://github.com/Fmstrat/zenbook-duo-linux),
the sister project this was built alongside.
