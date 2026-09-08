#!/bin/bash
#
# Standalone verification: for every drm.edid_firmware= entry configured
# in /etc/default/grub, confirm that:
#   1. the referenced firmware file actually exists under /lib/firmware
#   2. the connector it's assigned to is connected
#   3. the connector's LIVE EDID (what the kernel is actually using right
#      now) is byte-for-byte identical to that firmware file
#
# (3) is the check that matters: GRUB being configured correctly doesn't
# guarantee the override is actually active on the running system -- a
# missing reboot, or a driver that reads its EDID override from the
# initramfs rather than the live filesystem, can both leave the old,
# un-patched EDID in effect despite correct configuration. Exits 0 only
# if every configured entry is confirmed live.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDID_TOOL="${SCRIPT_DIR}/edid_tool.py"
GRUB_FILE=/etc/default/grub

# usage()
#
# Intent: print this script's command reference. Called for -h/--help;
# this script otherwise takes no other flags, only optional connector
# names, so there's nothing else to document here.
usage() {
    echo "Usage: $0 [connector ...]"
    echo
    echo "With no arguments, verifies every drm.edid_firmware= entry found"
    echo "in ${GRUB_FILE}. Pass one or more connector names (e.g. eDP-2) to"
    echo "check only those."
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if ! command -v python3 >/dev/null; then
    echo "python3 is required." >&2
    exit 1
fi

if [ ! -r "${GRUB_FILE}" ]; then
    echo "Cannot read ${GRUB_FILE}." >&2
    exit 1
fi

# Pull just the value inside GRUB_CMDLINE_LINUX="...", then pull just
# the drm.edid_firmware=... token's value out of that -- \K resets the
# match start so -o only captures what follows it, not the whole line.
# `|| true` on both since grep exits non-zero (not an error here) when
# the pattern simply isn't present, e.g. a bare cmdline with no override
# configured yet.
cmdline="$(grep -oP '^GRUB_CMDLINE_LINUX="\K[^"]*' "${GRUB_FILE}" || true)"
edid_param="$(echo "${cmdline}" | grep -oP 'drm\.edid_firmware=\K\S*' || true)"

if [ -z "${edid_param}" ]; then
    echo "No drm.edid_firmware= entries found in ${GRUB_FILE}."
    echo "Nothing to verify."
    exit 0
fi

# Parse the comma-separated connector:file list (e.g.
# "eDP-1:a.bin,eDP-2:b.bin") into an associative array keyed by
# connector name, so each one can be looked up and checked individually
# below.
declare -A configured
IFS=',' read -ra pairs <<< "${edid_param}"
for pair in "${pairs[@]}"; do
    conn="${pair%%:*}"
    ref="${pair#*:}"
    configured["${conn}"]="${ref}"
done

# Filter to requested connectors, if any were given: drop any entry from
# `configured` that isn't in `wanted`, then separately warn about any
# requested connector that had no configured entry to begin with (so a
# typo'd connector name doesn't just get silently ignored).
wanted=("$@")
if [ "${#wanted[@]}" -gt 0 ]; then
    for conn in "${!configured[@]}"; do
        keep=false
        for w in "${wanted[@]}"; do
            [ "${w}" = "${conn}" ] && keep=true
        done
        [ "${keep}" = true ] || unset 'configured[$conn]'
    done
    for w in "${wanted[@]}"; do
        # The +x expansion tests key existence without triggering
        # `set -u` on an unset array element (a plain
        # ${configured[$w]} would error out under nounset if $w was
        # never a key).
        if [ -z "${configured[${w}]+x}" ]; then
            echo "WARN: ${w} has no drm.edid_firmware= entry configured -- skipping"
        fi
    done
fi

if [ "${#configured[@]}" -eq 0 ]; then
    echo "Nothing matched to verify."
    exit 1
fi

overall=0
for conn in "${!configured[@]}"; do
    ref="${configured[${conn}]}"
    fw_path="/lib/firmware/${ref}"
    echo "=== ${conn} (configured: drm.edid_firmware=${conn}:${ref}) ==="

    if [ ! -r "${fw_path}" ]; then
        echo "FAIL: firmware file not found or not readable: ${fw_path}"
        overall=1
        echo
        continue
    fi

    sys_dir="$(ls -d /sys/class/drm/*-"${conn}" 2>/dev/null | head -n1)"
    if [ -z "${sys_dir}" ]; then
        echo "FAIL: no /sys/class/drm connector matches '${conn}'"
        overall=1
        echo
        continue
    fi

    status="$(cat "${sys_dir}/status" 2>/dev/null || echo unknown)"
    if [ "${status}" != connected ]; then
        echo "FAIL: ${conn} is not connected (status: ${status})"
        overall=1
        echo
        continue
    fi

    live_tmp="$(mktemp)"
    cat "${sys_dir}/edid" > "${live_tmp}" 2>/dev/null

    if ! cmp -s "${live_tmp}" "${fw_path}"; then
        echo "FAIL: live EDID does not match the configured firmware file."
        echo "      The override is configured but NOT currently active."
        echo "      Live EDID:"
        python3 "${EDID_TOOL}" info "${live_tmp}" 2>/dev/null | sed 's/^/        /'
        echo "      Configured firmware:"
        python3 "${EDID_TOOL}" info "${fw_path}" 2>/dev/null | sed 's/^/        /'
        echo "      Try rebooting if you haven't since installing it, or run"
        echo "      'sudo update-initramfs -u' if your driver loads EDID"
        echo "      overrides before the root filesystem is available."
        overall=1
    else
        echo "PASS: live EDID matches the configured firmware file exactly."
        python3 "${EDID_TOOL}" info "${live_tmp}" 2>/dev/null | sed 's/^/  /'
    fi
    rm -f "${live_tmp}"
    echo
done

exit "${overall}"
