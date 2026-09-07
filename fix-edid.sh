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

usage() {
    cat <<EOF
Usage:
  $0 list
      Show all connected DRM outputs with a valid EDID, grouped by
      identical panel identity (manufacturer/product/serial) so you can
      see which connectors are indistinguishable from each other.

  $0 fix <connector> [--serial N] [--dry-run]
      Patch <connector>'s EDID with a new serial number and install it
      as a boot-time override. Defaults to picking a serial number one
      higher than the highest one currently seen among its duplicate
      group. --dry-run shows what would happen without changing anything.

  $0 verify <connector>
      Check whether the override for <connector> is actually active on
      the currently running system (i.e. you've rebooted since fixing).

  $0 revert <connector>
      Remove the override for <connector>: drops it from the GRUB
      cmdline and deletes the installed firmware file.

A reboot is required after 'fix' or 'revert' for the change to take effect.
EOF
}

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

# Print one line per connected, EDID-bearing connector:
# connector<TAB>serial<TAB>product_name<TAB>identity_key
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
    echo "${rows}" | cut -f4 | sort | uniq -c | sort -rn | while read -r count identity; do
        if [ "${count}" -gt 1 ]; then
            echo "  - $(echo "${rows}" | awk -F'\t' -v id="${identity}" '$4==id {printf "%s ", $1}')"
        fi
    done
}

find_connector_row() {
    local want="$1"
    scan_connectors | awk -F'\t' -v want="${want}" '$1==want {print; found=1} END{exit !found}'
}

cmd_fix() {
    local connector="$1"; shift
    local new_serial="" dry_run=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --serial) new_serial="$2"; shift 2 ;;
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

    if [ -z "${new_serial}" ]; then
        # Pick one higher than the max serial among the same duplicate group.
        local max_serial=0 s
        while IFS=$'\t' read -r c s p id t; do
            [ "${id}" = "${identity}" ] || { rm -f "${t}"; continue; }
            [ "${s}" -gt "${max_serial}" ] && max_serial="${s}"
            rm -f "${t}"
        done < <(scan_connectors)
        new_serial=$((max_serial + 1))
    fi

    echo "Connector:       eDP-... (${connector})"
    echo "Product:         ${product}"
    echo "Current serial:  ${current_serial}"
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

# Merge/replace this connector's entry within GRUB_CMDLINE_LINUX's
# drm.edid_firmware=conn1:file1,conn2:file2 comma list.
update_grub_cmdline() {
    local connector="$1" fw_ref="$2"
    local backup="${GRUB_FILE}.bak-$(date +%Y%m%d%H%M%S)"
    sudo cp "${GRUB_FILE}" "${backup}"
    echo "Backed up ${GRUB_FILE} to ${backup}"

    sudo python3 - "${GRUB_FILE}" "${connector}" "${fw_ref}" <<'PYEOF'
import re
import sys

grub_file, connector, fw_ref = sys.argv[1:4]

with open(grub_file) as f:
    lines = f.readlines()

pattern = re.compile(r'^(GRUB_CMDLINE_LINUX=)"(.*)"\s*$')
found = False
for i, line in enumerate(lines):
    m = pattern.match(line)
    if not m:
        continue
    found = True
    prefix, value = m.group(1), m.group(2)
    tokens = value.split()
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
    entries[connector] = fw_ref
    new_edid_tok = "drm.edid_firmware=" + ",".join(f"{c}:{r}" for c, r in entries.items())
    new_value = " ".join(other_tokens + [new_edid_tok])
    lines[i] = f'{prefix}"{new_value}"\n'
    break

if not found:
    lines.append(f'GRUB_CMDLINE_LINUX="drm.edid_firmware={connector}:{fw_ref}"\n')

with open(grub_file, "w") as f:
    f.writelines(lines)
PYEOF

    echo "Updated GRUB_CMDLINE_LINUX in ${GRUB_FILE}"
    sudo update-grub
}

cmd_verify() {
    local connector="$1"
    local dir="/sys/class/drm/*-${connector}"
    local status_file
    status_file=$(ls -d ${dir}/status 2>/dev/null | head -n1) || true
    if [ -z "${status_file}" ]; then
        echo "Connector '${connector}' not found under /sys/class/drm." >&2
        exit 1
    fi
    local edid_file="${status_file%status}edid"
    local tmp
    tmp="$(mktemp)"
    cat "${edid_file}" > "${tmp}"
    echo "Live EDID currently in use for ${connector}:"
    python3 "${EDID_TOOL}" info "${tmp}"
    rm -f "${tmp}"

    local fw_file
    fw_file=$(grep -o "${connector}:edid/[^, \"]*" "${GRUB_FILE}" 2>/dev/null | head -n1 | cut -d: -f2) || true
    if [ -z "${fw_file}" ]; then
        echo
        echo "No drm.edid_firmware entry found for ${connector} in ${GRUB_FILE}."
        exit 1
    fi
    echo
    echo "Configured override file: /lib/firmware/${fw_file}"
    if [ -r "/lib/firmware/${fw_file}" ]; then
        python3 "${EDID_TOOL}" info "/lib/firmware/${fw_file}"
    else
        echo "(not readable -- check it was installed correctly)"
    fi
}

cmd_revert() {
    local connector="$1"
    local backup="${GRUB_FILE}.bak-$(date +%Y%m%d%H%M%S)"
    sudo cp "${GRUB_FILE}" "${backup}"
    echo "Backed up ${GRUB_FILE} to ${backup}"

    sudo python3 - "${GRUB_FILE}" "${connector}" <<'PYEOF'
import re
import sys

grub_file, connector = sys.argv[1:3]

with open(grub_file) as f:
    lines = f.readlines()

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
            entries.pop(connector, None)
            if entries:
                other_tokens.append("drm.edid_firmware=" + ",".join(f"{c}:{r}" for c, r in entries.items()))
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
            [ $# -eq 1 ] || { usage; exit 1; }
            cmd_verify "$1"
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
