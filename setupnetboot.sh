#!/bin/bash
set -e

# ─────────────────────────────────────────────
# Configuration – edit these before running
# ─────────────────────────────────────────────
ALPINE_IP="192.168.1.10"                  # IP of this Alpine PXE server
ISO_URL="https://example.com/your.iso"    # URL to download the ISO (or leave blank to copy manually)
ISO_NAME="boot.iso"                       # Filename for the ISO
TFTP_ROOT="/srv/tftp"
HTTP_ROOT="/srv/http"
# ISO is stored under TFTP root so memdisk (BIOS) can fetch it via TFTP,
# and nginx exposes the same directory over HTTP for UEFI / GRUB loopback.
ISO_DIR="${TFTP_ROOT}/iso"

# ─────────────────────────────────────────────
# Install required packages
# ─────────────────────────────────────────────
echo "==> Updating apk and installing packages..."
apk update
apk add dnsmasq syslinux nginx wget curl bash grub grub-efi

# ─────────────────────────────────────────────
# Set up TFTP directory structure
# ─────────────────────────────────────────────
echo "==> Setting up TFTP root at ${TFTP_ROOT}..."
mkdir -p "${TFTP_ROOT}/pxelinux.cfg"
mkdir -p "${TFTP_ROOT}/efi64/grub"
mkdir -p "${ISO_DIR}"

# Copy BIOS PXE bootloaders from syslinux
# NOTE: lpxelinux.0 is the HTTP/FTP-enabled PXELINUX variant (built with lwIP).
# It is required because we load the ISO from HTTP via the INITRD directive.
# We copy it to TFTP under the name pxelinux.0 so existing DHCP configs keep working.
echo "==> Copying BIOS syslinux bootloaders..."
if [ -f /usr/share/syslinux/lpxelinux.0 ]; then
    cp /usr/share/syslinux/lpxelinux.0  "${TFTP_ROOT}/pxelinux.0"
else
    echo "WARNING: lpxelinux.0 not found – falling back to pxelinux.0 (HTTP boot will NOT work)."
    cp /usr/share/syslinux/pxelinux.0   "${TFTP_ROOT}/pxelinux.0"
fi
cp /usr/share/syslinux/ldlinux.c32      "${TFTP_ROOT}/"
cp /usr/share/syslinux/libcom32.c32     "${TFTP_ROOT}/"
cp /usr/share/syslinux/libutil.c32      "${TFTP_ROOT}/"
cp /usr/share/syslinux/menu.c32         "${TFTP_ROOT}/"
cp /usr/share/syslinux/vesamenu.c32     "${TFTP_ROOT}/" 2>/dev/null || true
cp /usr/share/syslinux/memdisk          "${TFTP_ROOT}/"
cp /usr/share/syslinux/reboot.c32       "${TFTP_ROOT}/" 2>/dev/null || true
cp /usr/share/syslinux/poweroff.c32     "${TFTP_ROOT}/" 2>/dev/null || true

# ─────────────────────────────────────────────
# Set up UEFI GRUB bootloader
# ─────────────────────────────────────────────
echo "==> Setting up UEFI GRUB bootloader..."

# Check what modules are available and build with compatible ones
GRUB_MODULES_DIR="/usr/lib/grub/x86_64-efi"
if [ -d "$GRUB_MODULES_DIR" ]; then
    # Use standard linux module instead of linuxefi for Alpine
    echo "==> Building GRUB EFI image with available modules..."
    grub-mkimage \
        --format=x86_64-efi \
        --output="${TFTP_ROOT}/efi64/bootx64.efi" \
        --prefix="(tftp,${ALPINE_IP})/efi64/grub" \
        efinet tftp http net boot linux normal configfile part_gpt \
        part_msdos fat iso9660 udf ext2 xfs btrfs squash4 \
        gzio all_video video_bochs video_cirrus \
        echo test true regexp probe chain halt reboot \
        search search_fs_file search_fs_uuid search_label \
        minicmd cat ls help loopback sleep
else
    echo "WARNING: GRUB EFI modules not found. Trying alternative approach..."
    # Use pre-built EFI file if available
    if [ -f "/usr/lib/grub/x86_64-efi-signed/grubx64.efi" ]; then
        cp "/usr/lib/grub/x86_64-efi-signed/grubx64.efi" "${TFTP_ROOT}/efi64/bootx64.efi"
    elif [ -f "/boot/efi/EFI/alpine/grubx64.efi" ]; then
        cp "/boot/efi/EFI/alpine/grubx64.efi" "${TFTP_ROOT}/efi64/bootx64.efi"
    else
        echo "ERROR: No GRUB EFI bootloader found. UEFI boot will not work."
        echo "BIOS boot will still function normally."
    fi
fi

# Create GRUB config for UEFI clients
cat > "${TFTP_ROOT}/efi64/grub/grub.cfg" <<EOF
set timeout=10
set default=0

menuentry "Boot from ISO (${ISO_NAME})" {
    echo "Mounting ISO via loopback (UEFI)..."
    # Detach any pre-existing loop device so we can re-enter this entry cleanly.
    # GRUB doesn't abort on non-zero return inside a menuentry, so an error
    # here (when 'loop' doesn't exist yet) is harmless.
    loopback -d loop
    loopback loop (http,${ALPINE_IP})/iso/${ISO_NAME}
    # Try the ISO's own GRUB config first (works for most modern Linux ISOs)
    if [ -f (loop)/boot/grub/grub.cfg ]; then
        configfile (loop)/boot/grub/grub.cfg
    elif [ -f (loop)/EFI/BOOT/grub.cfg ]; then
        configfile (loop)/EFI/BOOT/grub.cfg
    else
        # Fallback: no embedded grub.cfg – we cannot reliably guess kernel paths
        # for an arbitrary ISO. Drop to GRUB shell so the user can investigate.
        echo "ERROR: No grub.cfg found inside the ISO."
        echo "Use the GRUB shell ('ls (loop)/' etc.) to inspect the ISO layout,"
        echo "then customize this menuentry with the correct linux/initrd paths."
        sleep 10
    fi
}

menuentry "Boot from Local Disk" {
    echo "Attempting to boot from local disk..."
    set root=(hd0)
    chainloader +1
}

menuentry "Reboot" {
    reboot
}

menuentry "Shutdown" {
    halt
}
EOF

# Also place bootx64.efi at the root for simpler DHCP filename config
if [ -f "${TFTP_ROOT}/efi64/bootx64.efi" ]; then
    cp "${TFTP_ROOT}/efi64/bootx64.efi" "${TFTP_ROOT}/bootx64.efi"
fi

# ─────────────────────────────────────────────
# Create PXE boot menu (BIOS / syslinux)
# ─────────────────────────────────────────────
echo "==> Creating BIOS PXE boot menu..."
cat > "${TFTP_ROOT}/pxelinux.cfg/default" <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE PXE Boot Menu (BIOS)

LABEL bootiso
  MENU LABEL Boot from ISO (${ISO_NAME})
  KERNEL memdisk
  INITRD iso/${ISO_NAME}
  APPEND iso raw

LABEL local
  MENU LABEL Boot from Local Disk
  LOCALBOOT 0

LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32

LABEL poweroff
  MENU LABEL Power Off
  COM32 poweroff.c32
EOF

# ─────────────────────────────────────────────
# Configure dnsmasq (TFTP only, no DHCP)
# DHCP (incl. arch-based filename selection) is handled by OPNsense.
# OPNsense must be configured to serve:
#   client-arch 0       (BIOS)        → pxelinux.0
#   client-arch 7 or 9  (UEFI x86_64) → efi64/bootx64.efi
# ─────────────────────────────────────────────
echo "==> Configuring dnsmasq for TFTP-only mode..."
cat > /etc/dnsmasq.conf <<EOF
# Disable dnsmasq DNS server
port=0

# Enable TFTP server
enable-tftp
tftp-root=${TFTP_ROOT}

# Log TFTP requests for debugging
log-queries
EOF

# ─────────────────────────────────────────────
# Set up Nginx to serve the ISO over HTTP
# ─────────────────────────────────────────────
echo "==> Configuring nginx..."
mkdir -p "${ISO_DIR}"
cat > /etc/nginx/http.d/pxe.conf <<EOF
server {
    listen 80;
    server_name ${ALPINE_IP};

    root ${HTTP_ROOT};
    autoindex on;

    # Serve ISOs with proper caching and chunked transfer
    location /iso/ {
        alias ${ISO_DIR}/;
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        
        # Allow large files and range requests for better download reliability
        client_max_body_size 4G;
        add_header Accept-Ranges bytes;
    }
    
    # Serve other TFTP files via HTTP as fallback
    location /tftp/ {
        alias ${TFTP_ROOT}/;
        autoindex on;
    }
}
EOF

# Remove default nginx site if present
rm -f /etc/nginx/http.d/default.conf

# ─────────────────────────────────────────────
# Download or remind user to place the ISO
# ─────────────────────────────────────────────
if [ -n "${ISO_URL}" ] && [ "${ISO_URL}" != "https://example.com/your.iso" ]; then
    if [ -f "${ISO_DIR}/${ISO_NAME}" ]; then
        echo "==> ISO already exists: ${ISO_DIR}/${ISO_NAME}"
        read -r -p "    Download again and overwrite? [y/N] " _iso_reply
        case "${_iso_reply}" in
            [yY][eE][sS]|[yY])
                echo "==> Re-downloading ISO from ${ISO_URL}..."
                wget -O "${ISO_DIR}/${ISO_NAME}" "${ISO_URL}"
                ;;
            *)
                echo "==> Keeping existing ISO."
                ;;
        esac
    else
        echo "==> Downloading ISO from ${ISO_URL}..."
        wget -O "${ISO_DIR}/${ISO_NAME}" "${ISO_URL}"
    fi
else
    echo "==> Please copy your ISO to: ${ISO_DIR}/${ISO_NAME}"
fi

# ─────────────────────────────────────────────
# Enable and start services
# ─────────────────────────────────────────────
echo "==> Enabling and starting services..."
rc-update add dnsmasq default
rc-update add nginx default

rc-service dnsmasq restart
rc-service nginx restart

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════"
echo " PXE Server setup complete!"
echo "══════════════════════════════════════════════"
echo ""
echo " TFTP Server : ${ALPINE_IP}"
echo " ISO served  : http://${ALPINE_IP}/iso/${ISO_NAME}"
echo ""
echo " OPNsense DHCP configuration required:"
echo "   Services → DHCPv4 → [Your Interface]"
echo "   → Network Booting:"
echo "     Enable           : ✔"
echo "     Next Server      : ${ALPINE_IP}"
echo "     Default BIOS     : pxelinux.0"
echo "     Default UEFI     : efi64/bootx64.efi"
echo ""
echo " Client boot files:"
echo "   BIOS clients  → pxelinux.0        (syslinux + memdisk)"
echo "   UEFI clients  → efi64/bootx64.efi (grub-efi)"
echo ""
echo " Test TFTP access:"
echo "   tftp ${ALPINE_IP}"
echo "   > get pxelinux.0"
echo "   > get efi64/bootx64.efi"
echo ""
echo " Test HTTP access:"
echo "   curl -I http://${ALPINE_IP}/iso/${ISO_NAME}"
echo ""