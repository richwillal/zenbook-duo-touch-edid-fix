#!/bin/bash
#
# zenbook-duo-touch-edid-fix
#
# Some dual-screen laptops (e.g. the ASUS Zenbook Duo) ship two physically
# identical panels reporting byte-for-byte identical EDID data, including
# a manufacturer serial number of 0 on both. Linux's touch-to-display
# matching can't tell the two displays apart in that case, so touch input
# ends up mapped to the wrong screen (or both).
#
# The fix: extract one panel's EDID, give it a distinct serial number
# (with a recomputed checksum), and tell the kernel to use that modified
# copy for that connector at boot via `drm.edid_firmware=`. This script
# automates that end to end.
#
# Must be run as a regular user with sudo available (mirrors duo.sh's
# own setup.sh convention) -- individual privileged steps use sudo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDID_TOOL="${SCRIPT_DIR}/edid_tool.py"
FIRMWARE_DIR=/lib/firmware/edid
GRUB_FILE=/etc/default/grub

# usage()
#
# Intent: print the tool's command reference to stdout. Called for -h/
# --help and whenever the user invokes a subcommand with missing/invalid
# arguments, so it doubles as both documentation and an error hint.
usage() {
    cat <<EOF
Usage:
  $0 list
      Show all connected DRM outputs with a valid EDID, grouped by
      identical panel identity (manufacturer/product/serial) so you can
      see which connectors are indistinguishable from each other.

  $0 fix <connector> [--serial N] [--dry-run]
      Patch <connector>'s EDID with a new serial number and install it
      as a boot-time override. Auto-picks a serial number one higher
      than the highest one currently seen among its duplicate group,
      and prompts interactively to accept or override it unless --serial
      is given or there's no terminal to prompt on. --dry-run shows what
      would happen without changing anything.

  $0 verify [connector ...]
      Check whether the configured override(s) are actually active on
      the currently running system (i.e. you've rebooted since fixing).
      With no arguments, verifies every configured connector. Equivalent
      to running ./verify-edid.sh directly.

  $0 revert <connector>
      Remove the override for <connector>: drops it from the GRUB
      cmdline and deletes the installed firmware file.

A reboot is required after 'fix' or 'revert' for the change to take effect.
EOF
}

# require_root_tools()
#
# Intent: fail fast with a clear message if either of this script's two
# hard dependencies (sudo, python3) is missing, rather than letting the
# real error surface confusingly deep inside cmd_fix/cmd_revert after
# the user has already answered prompts.
require_root_tools() {
    if ! command -v sudo >/dev/null; then
        echo "This script needs sudo to write firmware files and update GRUB." >&2
        exit 1
    fi
    if ! command -v python3 >/dev/null; then
        echo "python3 is required (used for EDID parsing/patching)." >&2
        exit 1
    fi
}

# scan_connectors()
#
# Intent: the single source of truth for "what displays are connected
# and what do their EDIDs say" -- every other function that needs that
# information (cmd_list, find_connector_row, the duplicate-group/serial
# logic in cmd_fix) calls this rather than re-implementing the scan, so
# the connected/valid-EDID filtering rules only exist in one place.
#
# Prints one line per connected, EDID-bearing connector in the form:
#   connector<TAB>serial<TAB>product_name<TAB>identity_key<TAB>tmpfile
# where tmpfile holds that connector's raw EDID bytes -- the caller is
# responsible for deleting it once done (this function can't clean up
# after itself since the whole point is to hand the data back).
scan_connectors() {
    for status_file in /sys/class/drm/*/status; do
        [ -e "${status_file}" ] || continue
        local dir connector edid_file size tmp
        dir="$(dirname "${status_file}")"
        connector="$(basename "${dir}")"
        [ "$(cat "${status_file}")" = connected ] || continue
        edid_file="${dir}/edid"
        [ -r "${edid_file}" ] || continue
        size="$(wc -c < "${edid_file}")"
        [ "${size}" -ge 128 ] || continue
        tmp="$(mktemp)"
        cat "${edid_file}" > "${tmp}"
        local info serial product identity
        info="$(python3 "${EDID_TOOL}" info "${tmp}" 2>/dev/null)" || { rm -f "${tmp}"; continue; }
        # Pull the individual fields we need back out of edid_tool.py's
        # JSON output -- simplest way to consume it from bash without a
        # dedicated JSON-parsing dependency.
        serial="$(echo "${info}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["serial"])')"
        product="$(echo "${info}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["product_name"] or "?")')"
        # identity = everything except the serial (bytes 0-11) and checksum,
        # so two panels of the same model/manufacturer group together
        # regardless of what serial they currently carry.
        identity="$(dd if="${tmp}" bs=1 skip=0 count=12 2>/dev/null | md5sum | cut -d' ' -f1)"
        # display name (short) shown to connector, e.g. card1-eDP-1 -> eDP-1
        local short="${connector#*-}"
        echo -e "${short}\t${serial}\t${product}\t${identity}\t${tmp}"
    done
}

# cmd_list()
#
# Intent: the `list` subcommand -- give the operator a human-readable
# table of connected displays plus an explicit call-out of any group
# that's currently indistinguishable to the OS (identical identity, i.e.
# same manufacturer/product), which is exactly the situation this whole
# tool exists to resolve. Read-only; makes no changes.
cmd_list() {
    echo "Connected displays:"
    echo
    printf "%-10s %-10s %-16s\n" "CONNECTOR" "SERIAL" "PRODUCT"
    local rows
    rows="$(scan_connectors)"
    if [ -z "${rows}" ]; then
        echo "(none found -- is this a laptop panel / eDP connector?)"
        return
    fi
    echo "${rows}" | while IFS=$'\t' read -r connector serial product identity tmp; do
        printf "%-10s %-10s %-16s\n" "${connector}" "${serial}" "${product}"
        rm -f "${tmp}"
    done
    echo
    echo "Duplicate groups (same panel identity -- these are indistinguishable to the OS):"
    # Count how many connectors share each identity key; any count > 1
    # is a duplicate group worth flagging. For each one, re-filter the
    # full row list down to just that identity and print the matching
    # connector names on one line.
    echo "${rows}" | cut -f4 | sort | uniq -c | sort -rn | while read -r count identity; do
        if [ "${count}" -gt 1 ]; then
            echo "  - $(echo "${rows}" | awk -F'\t' -v id="${identity}" '$4==id {printf "%s ", $1}')"
        fi
    done
}

# find_connector_row(connector_name)
#
# Intent: look up a single connector's scan_connectors() row by its
# short name (e.g. "eDP-2"), so cmd_fix doesn't need to re-scan and
# filter inline. Fails (non-zero exit, no output) if no connected,
# EDID-bearing connector matches the given name.
find_connector_row() {
    local want="$1"
    # `found` is set inside the awk program only when a matching line is
    # printed; END{exit !found} turns "no match" into a real non-zero
    # exit code, since awk normally exits 0 regardless of whether any
    # pattern matched.
    scan_connectors | awk -F'\t' -v want="${want}" '$1==want {print; found=1} END{exit !found}'
}

# cmd_fix(connector, [--serial N], [--dry-run])
#
# Intent: the `fix` subcommand and the heart of this tool -- patch the
# given connector's EDID with a new (non-conflicting) serial number,
# then install it as a boot-time drm.edid_firmware= override. Handles
# picking a safe default serial, letting the operator confirm/override
# it interactively, previewing everything under --dry-run, and only
# touching the filesystem/GRUB after an explicit confirmation.
cmd_fix() {
    local connector="$1"; shift
    local new_serial="" serial_given=false dry_run=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --serial) new_serial="$2"; serial_given=true; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    local row
    row="$(find_connector_row "${connector}")" || {
        echo "Connector '${connector}' not found among connected displays with a valid EDID." >&2
        echo "Run '$0 list' to see what's available." >&2
        exit 1
    }
    IFS=$'\t' read -r _ current_serial product identity tmp_edid <<< "${row}"

    # group_serials()
    #
    # Intent: list the serial numbers currently in use by every
    # connector sharing this one's identity (i.e. its "duplicate
    # group"), used both to auto-pick a non-conflicting default and to
    # reject a manually-entered serial that would collide with a panel
    # already in the group. Defined inside cmd_fix (rather than
    # top-level) because it closes over `identity`, computed just above
    # from the connector this invocation of `fix` is operating on.
    group_serials() {
        local s
        while IFS=$'\t' read -r c s p id t; do
            [ "${id}" = "${identity}" ] || { rm -f "${t}"; continue; }
            echo "${s}"
            rm -f "${t}"
        done < <(scan_connectors)
    }

    # Default suggestion: one higher than the highest serial already
    # seen in this duplicate group, so it can never collide with an
    # existing panel regardless of what values they currently hold.
    local auto_picked=0 s
    while read -r s; do
        [ "${s}" -gt "${auto_picked}" ] && auto_picked="${s}"
    done < <(group_serials)
    auto_picked=$((auto_picked + 1))

    echo "Connector:       eDP-... (${connector})"
    echo "Product:         ${product}"
    echo "Current serial:  ${current_serial}"

    if ${serial_given}; then
        if ! [[ "${new_serial}" =~ ^[0-9]+$ ]]; then
            echo "Serial must be a non-negative integer, got: ${new_serial}" >&2
            exit 1
        fi
        if group_serials | grep -qx "${new_serial}"; then
            echo "Serial ${new_serial} is already in use by another panel in this group -- pick a different one." >&2
            exit 1
        fi
    fi

    if [ -z "${new_serial}" ]; then
        new_serial="${auto_picked}"
    fi

    # Prompt interactively unless a serial was already given on the
    # command line, or there's no terminal to prompt on (e.g. running
    # from a script or CI) -- this matters if a future ASUS revision
    # ships a different default serial and the auto-picked value needs
    # a manual override without having to know about --serial up front.
    if ! ${serial_given} && [ -t 0 ]; then
        echo "Auto-picked new serial: ${auto_picked}"
        while true; do
            read -r -p "Enter serial to use [${auto_picked}]: " entered
            [ -z "${entered}" ] && entered="${auto_picked}"
            if ! [[ "${entered}" =~ ^[0-9]+$ ]]; then
                echo "Serial must be a non-negative integer." >&2
                continue
            fi
            if group_serials | grep -qx "${entered}"; then
                echo "Serial ${entered} is already in use by another panel in this group -- pick a different one." >&2
                continue
            fi
            new_serial="${entered}"
            break
        done
    fi

    echo "New serial:      ${new_serial}"

    local out_name="${connector//\//-}.bin"
    local out_path="/tmp/${out_name}"
    python3 "${EDID_TOOL}" patch "${tmp_edid}" "${out_path}" "${new_serial}"
    rm -f "${tmp_edid}"

    echo
    echo "Patched EDID (128-byte base block + any extension blocks, unchanged"
    echo "except the serial field and its checksum) written to: ${out_path}"

    local grub_line="drm.edid_firmware=${connector}:edid/${out_name}"

    if ${dry_run}; then
        echo
        echo "[dry run] Would install:  ${FIRMWARE_DIR}/${out_name}"
        echo "[dry run] Would ensure GRUB_CMDLINE_LINUX in ${GRUB_FILE} contains:"
        echo "[dry run]   ${grub_line}"
        echo "[dry run] Would then run: sudo update-grub"
        echo
        echo "No changes made. Re-run without --dry-run to apply."
        return
    fi

    echo
    read -r -p "Apply this now? This will modify ${GRUB_FILE} and run update-grub. [y/N] " confirm
    if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
        echo "Aborted, nothing changed."
        exit 0
    fi

    sudo mkdir -p "${FIRMWARE_DIR}"
    sudo cp "${out_path}" "${FIRMWARE_DIR}/${out_name}"
    sudo chmod 0644 "${FIRMWARE_DIR}/${out_name}"
    echo "Installed: ${FIRMWARE_DIR}/${out_name}"

    update_grub_cmdline "${connector}" "edid/${out_name}"

    echo
    echo "Done. Reboot required for the change to take effect."
    echo "After rebooting, run: $0 verify ${connector}"
}

# update_grub_cmdline(connector, fw_ref)
#
# Intent: wire up the installed firmware file as a real boot-time
# override by merging/replacing this connector's entry within
# GRUB_CMDLINE_LINUX's drm.edid_firmware=conn1:file1,conn2:file2 comma
# list in /etc/default/grub, then regenerating the actual boot config
# with update-grub. Backs up the config file first since this is
# editing a file that controls how the machine boots.
update_grub_cmdline() {
    local connector="$1" fw_ref="$2"
    local backup="${GRUB_FILE}.bak-$(date +%Y%m%d%H%M%S)"
    sudo cp "${GRUB_FILE}" "${backup}"
    echo "Backed up ${GRUB_FILE} to ${backup}"

    # Intent: add or update this connector's drm.edid_firmware= entry in
    # /etc/default/grub's GRUB_CMDLINE_LINUX line without disturbing any
    # other kernel parameters already there, and without clobbering
    # other connectors that might already have their own EDID override
    # (the kernel parameter supports a comma-separated list of
    # connector:file pairs, e.g. "eDP-1:a.bin,eDP-2:b.bin").
    sudo python3 - "${GRUB_FILE}" "${connector}" "${fw_ref}" <<'PYEOF'
import re
import sys

grub_file, connector, fw_ref = sys.argv[1:4]

with open(grub_file) as f:
    lines = f.readlines()

# Matches a line like GRUB_CMDLINE_LINUX="quiet splash foo=bar" and
# captures the variable-name prefix and the quoted value separately, so
# we can rewrite just the value while leaving the rest of the line
# (indentation, trailing whitespace shape) alone.
pattern = re.compile(r'^(GRUB_CMDLINE_LINUX=)"(.*)"\s*$')
found = False
for i, line in enumerate(lines):
    m = pattern.match(line)
    if not m:
        continue
    found = True
    prefix, value = m.group(1), m.group(2)
    tokens = value.split()
    # entries holds any existing drm.edid_firmware= connector:file pairs
    # (as a dict so re-running this for the same connector overwrites
    # its entry instead of appending a duplicate); other_tokens holds
    # every unrelated kernel parameter, preserved as-is and in order.
    entries = {}
    other_tokens = []
    for tok in tokens:
        if tok.startswith("drm.edid_firmware="):
            for pair in tok[len("drm.edid_firmware="):].split(","):
                if ":" in pair:
                    conn, ref = pair.split(":", 1)
                    entries[conn] = ref
        else:
            other_tokens.append(tok)
    # Add/replace this connector's entry, then serialize the whole dict
    # back into the single comma-separated drm.edid_firmware= token the
    # kernel expects.
    entries[connector] = fw_ref
    new_edid_tok = "drm.edid_firmware=" + ",".join(f"{c}:{r}" for c, r in entries.items())
    new_value = " ".join(other_tokens + [new_edid_tok])
    lines[i] = f'{prefix}"{new_value}"\n'
    break

if not found:
    # No GRUB_CMDLINE_LINUX line existed at all yet -- create one rather
    # than erroring out, so this works on a config that never had a
    # custom cmdline before.
    lines.append(f'GRUB_CMDLINE_LINUX="drm.edid_firmware={connector}:{fw_ref}"\n')

with open(grub_file, "w") as f:
    f.writelines(lines)
PYEOF

    echo "Updated GRUB_CMDLINE_LINUX in ${GRUB_FILE}"
    sudo update-grub
}

# cmd_verify([connector ...])
#
# Intent: the `verify` subcommand. Delegates to verify-edid.sh -- the
# canonical live-EDID-vs-configured-firmware comparison -- rather than
# re-implementing that check here, so there's exactly one implementation
# of it that both entry points share instead of two that could drift
# apart.
cmd_verify() {
    "${SCRIPT_DIR}/verify-edid.sh" "$@"
}

# cmd_revert(connector)
#
# Intent: the `revert` subcommand -- undo cmd_fix for a given connector.
# Removes its entry from GRUB_CMDLINE_LINUX (backing up the config file
# first, same as update_grub_cmdline), deletes the installed firmware
# file, and regenerates the boot config. A reboot is still required
# afterward for the live system to stop using the override.
cmd_revert() {
    local connector="$1"
    local backup="${GRUB_FILE}.bak-$(date +%Y%m%d%H%M%S)"
    sudo cp "${GRUB_FILE}" "${backup}"
    echo "Backed up ${GRUB_FILE} to ${backup}"

    # Intent: the inverse of update_grub_cmdline() above -- remove just
    # this connector's entry from the drm.edid_firmware= comma list
    # (dropping the whole parameter if it was the only entry), leaving
    # every other kernel parameter, and any other connector's override,
    # untouched.
    sudo python3 - "${GRUB_FILE}" "${connector}" <<'PYEOF'
import re
import sys

grub_file, connector = sys.argv[1:3]

with open(grub_file) as f:
    lines = f.readlines()

# Same GRUB_CMDLINE_LINUX="..." matcher as update_grub_cmdline() uses.
pattern = re.compile(r'^(GRUB_CMDLINE_LINUX=)"(.*)"\s*$')
for i, line in enumerate(lines):
    m = pattern.match(line)
    if not m:
        continue
    prefix, value = m.group(1), m.group(2)
    tokens = value.split()
    other_tokens = []
    for tok in tokens:
        if tok.startswith("drm.edid_firmware="):
            entries = {}
            for pair in tok[len("drm.edid_firmware="):].split(","):
                if ":" in pair:
                    conn, ref = pair.split(":", 1)
                    entries[conn] = ref
            # Drop this connector specifically; any other connectors'
            # overrides in the same comma list are kept.
            entries.pop(connector, None)
            if entries:
                other_tokens.append("drm.edid_firmware=" + ",".join(f"{c}:{r}" for c, r in entries.items()))
            # else: no entries left at all, so drop the whole
            # drm.edid_firmware= token rather than leaving an empty one.
        else:
            other_tokens.append(tok)
    lines[i] = f'{prefix}"{" ".join(other_tokens)}"\n'
    break

with open(grub_file, "w") as f:
    f.writelines(lines)
PYEOF

    local fw_name="${connector}.bin"
    if [ -f "${FIRMWARE_DIR}/${fw_name}" ]; then
        sudo rm -f "${FIRMWARE_DIR}/${fw_name}"
        echo "Removed ${FIRMWARE_DIR}/${fw_name}"
    fi

    sudo update-grub
    echo
    echo "Reverted. Reboot required for the change to take effect."
}

# main(args...)
#
# Intent: the script's single entry point -- validates the two hard
# dependencies are present, then dispatches to the requested subcommand
# based on argv[1], falling back to usage() for -h/--help, no arguments,
# or anything unrecognized.
main() {
    require_root_tools
    local sub="${1:-}"
    case "${sub}" in
        list) cmd_list ;;
        fix)
            shift
            [ $# -ge 1 ] || { usage; exit 1; }
            cmd_fix "$@"
            ;;
        verify)
            shift
            cmd_verify "$@"
            ;;
        revert)
            shift
            [ $# -eq 1 ] || { usage; exit 1; }
            cmd_revert "$1"
            ;;
        -h|--help|"") usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
