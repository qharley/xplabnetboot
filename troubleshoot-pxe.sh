#!/bin/sh
# PXE server troubleshooter – run this on the Alpine PXE server as root.
# Usage: sh troubleshoot-pxe.sh

ALPINE_IP="${1:-$(ip route get 1 | awk '{print $7;exit}')}"
TFTP_ROOT="/srv/tftp"
HTTP_ROOT="/srv/http"
ISO_DIR="${HTTP_ROOT}/iso"
ISO_CONTENTS="${HTTP_ROOT}/iso-contents"

PASS=0; FAIL=0

ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }
hr()   { echo "────────────────────────────────────────────"; }

hr
echo " PXE Troubleshooter  –  server IP: ${ALPINE_IP}"
hr

# ── 1. ISO file ──────────────────────────────
echo ""
echo "1. ISO file"
ISO_FILE="$(ls -1t "${ISO_DIR}"/*.iso 2>/dev/null | head -1)"
if [ -n "${ISO_FILE}" ]; then
    ok "ISO found: ${ISO_FILE} ($(du -h "${ISO_FILE}" | cut -f1))"
else
    fail "No *.iso found in ${ISO_DIR}"
fi

# ── 2. Squashfs extraction ───────────────────
echo ""
echo "2. Squashfs files in ${ISO_CONTENTS}/live/"
if [ -d "${ISO_CONTENTS}/live" ]; then
    SQ="$(ls -1 "${ISO_CONTENTS}/live/"*.squashfs 2>/dev/null)"
    if [ -n "${SQ}" ]; then
        ok "Squashfs files:"
        for F in ${SQ}; do echo "       $F ($(du -h "$F" | cut -f1))"; done
    else
        fail "No *.squashfs in ${ISO_CONTENTS}/live/"
        info "Contents of ${ISO_CONTENTS}/live/:"
        ls -lh "${ISO_CONTENTS}/live/" 2>/dev/null || echo "       (empty or missing)"
    fi
else
    fail "${ISO_CONTENTS}/live/ does not exist"
    info "Run: xorriso -osirrox on -indev ${ISO_FILE:-YOUR.iso} -extract /live ${ISO_CONTENTS}/live"
fi

# ── 3. nginx serving /iso-contents/ ──────────
echo ""
echo "3. HTTP: /iso-contents/"
HTTP_IDX="$(wget -q -O- "http://${ALPINE_IP}/iso-contents/" 2>&1 | head -3)"
if echo "${HTTP_IDX}" | grep -qi "live\|html"; then
    ok "http://${ALPINE_IP}/iso-contents/ is reachable"
else
    fail "http://${ALPINE_IP}/iso-contents/ returned unexpected response"
    info "Response: ${HTTP_IDX}"
fi

# ── 4. Squashfs HTTP fetch ────────────────────
echo ""
echo "4. HTTP: squashfs file"
for F in "${ISO_CONTENTS}/live/"*.squashfs; do
    [ -f "${F}" ] || continue
    FNAME="$(basename "${F}")"
    URL="http://${ALPINE_IP}/iso-contents/live/${FNAME}"
    STATUS="$(wget -q --spider --server-response "${URL}" 2>&1 \
        | awk '/HTTP\//{print $2}' | tail -1)"
    if [ "${STATUS}" = "200" ]; then
        ok "HTTP 200  ${URL}"
    else
        fail "HTTP ${STATUS:-no response}  ${URL}"
        info "nginx error log tail:"
        tail -5 /var/log/nginx/error.log 2>/dev/null || echo "       (no error log)"
    fi
done

# ── 5. TFTP files ─────────────────────────────
echo ""
echo "5. TFTP: key boot files"
for F in lpxelinux.0 pxelinux.0 ldlinux.c32 menu.c32 "iso-boot/vmlinuz" "iso-boot/initrd"; do
    if [ -f "${TFTP_ROOT}/${F}" ]; then
        ok "${F}  ($(du -h "${TFTP_ROOT}/${F}" | cut -f1))"
    else
        fail "${F}  MISSING from ${TFTP_ROOT}"
    fi
done

# ── 6. PXE menu content ───────────────────────
echo ""
echo "6. PXE BIOS menu: ${TFTP_ROOT}/pxelinux.cfg/default"
if [ -f "${TFTP_ROOT}/pxelinux.cfg/default" ]; then
    if grep -q "bootiso" "${TFTP_ROOT}/pxelinux.cfg/default"; then
        ok "LABEL bootiso entry found"
        grep -E "KERNEL|INITRD|APPEND" "${TFTP_ROOT}/pxelinux.cfg/default" \
            | sed 's/^/       /'
    else
        fail "No LABEL bootiso in menu"
        cat "${TFTP_ROOT}/pxelinux.cfg/default"
    fi
else
    fail "File missing"
fi

# If menu uses INCLUDE, check the included file instead
INCLUDED_CFG="$(grep -i '^INCLUDE ' "${TFTP_ROOT}/pxelinux.cfg/default" 2>/dev/null \
    | awk '{print $2}' | head -1)"
if [ -n "${INCLUDED_CFG}" ]; then
    INCLUDED_PATH="${TFTP_ROOT}/${INCLUDED_CFG}"
    echo ""
    echo "6b. Included syslinux config: ${INCLUDED_PATH}"
    if [ -f "${INCLUDED_PATH}" ]; then
        ENTRY_COUNT="$(grep -ci '^LABEL' "${INCLUDED_PATH}" || echo 0)"
        ok "Found ${ENTRY_COUNT} LABEL entries in included config"
        grep -iE "^LABEL|KERNEL|INITRD|APPEND" "${INCLUDED_PATH}" | head -30 | sed 's/^/       /'
        echo ""
        echo "6c. GRUB config: ${TFTP_ROOT}/efi64/grub/grub.cfg"
        if [ -f "${TFTP_ROOT}/efi64/grub/grub.cfg" ]; then
            ME_COUNT="$(grep -c '^menuentry' "${TFTP_ROOT}/efi64/grub/grub.cfg" || echo 0)"
            ok "Found ${ME_COUNT} menuentry entries in grub.cfg"
            grep -E "menuentry|linux |initrd " "${TFTP_ROOT}/efi64/grub/grub.cfg" | head -20 | sed 's/^/       /'
        else
            fail "efi64/grub/grub.cfg missing"
        fi
        echo ""
        echo "6d. GRUB fonts/themes (needed for splash):"
        if [ -d "${TFTP_ROOT}/boot/grub" ]; then
            ok "${TFTP_ROOT}/boot/grub exists"
            ls -lh "${TFTP_ROOT}/boot/grub/" | head -15 | sed 's/^/       /'
        else
            fail "${TFTP_ROOT}/boot/grub missing – GRUB splash/fonts will fail"
            info "Re-run setupnetboot.sh to extract /boot/grub/ from the ISO"
        fi
    else
        fail "Included file not found: ${INCLUDED_PATH}"
    fi
fi

# ── 7. Services ───────────────────────────────
echo ""
echo "7. Services"
rc-service nginx status  2>&1 | grep -q "started" && ok "nginx running"  || fail "nginx not running"
rc-service dnsmasq status 2>&1 | grep -q "started" && ok "dnsmasq running" || fail "dnsmasq not running"

# ── Summary ───────────────────────────────────
echo ""
hr
echo " Result: ${PASS} passed, ${FAIL} failed"
hr
echo ""
if [ "${FAIL}" -gt 0 ]; then
    echo "Quick fixes:"
    echo ""
    echo "  # Re-extract live/ from ISO:"
    echo "  xorriso -osirrox on -indev ${ISO_FILE:-${ISO_DIR}/boot.iso} \\"
    echo "    -extract /live ${ISO_CONTENTS}/live"
    echo ""
    echo "  # Verify squashfs URL:"
    SQ2="$(ls -1 "${ISO_CONTENTS}/live/"*.squashfs 2>/dev/null | head -1)"
    SQNAME="$(basename "${SQ2:-filesystem.squashfs}")"
    echo "  wget -q --spider http://${ALPINE_IP}/iso-contents/live/${SQNAME} && echo OK"
    echo ""
    echo "  # Restart nginx:"
    echo "  rc-service nginx restart"
fi
