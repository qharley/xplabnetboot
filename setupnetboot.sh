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
ISO_DIR="${HTTP_ROOT}/iso"

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

# Copy BIOS PXE bootloaders from syslinux
# NOTE: lpxelinux.0 is used (in addition to pxelinux.0) because it supports
# HTTP/FTP in addition to TFTP. The standard pxelinux.0 can only fetch files
# over TFTP, so APPEND lines referring to http://... URLs silently fail and
# the PXE menu loops. DHCP serves lpxelinux.0 by default below.
echo "==> Copying BIOS syslinux bootloaders..."
cp /usr/share/syslinux/pxelinux.0       "${TFTP_ROOT}/"
cp /usr/share/syslinux/lpxelinux.0      "${TFTP_ROOT}/" 2>/dev/null || \
    echo "WARNING: lpxelinux.0 not found – HTTP fetch from BIOS PXE will not work."
cp /usr/share/syslinux/ldlinux.c32      "${TFTP_ROOT}/"
cp /usr/share/syslinux/libcom32.c32     "${TFTP_ROOT}/"
cp /usr/share/syslinux/libutil.c32      "${TFTP_ROOT}/"
cp /usr/share/syslinux/menu.c32         "${TFTP_ROOT}/"
cp /usr/share/syslinux/vesamenu.c32     "${TFTP_ROOT}/" 2>/dev/null || true
cp /usr/share/syslinux/reboot.c32       "${TFTP_ROOT}/" 2>/dev/null || true
cp /usr/share/syslinux/poweroff.c32     "${TFTP_ROOT}/" 2>/dev/null || true
cp /usr/share/syslinux/memdisk          "${TFTP_ROOT}/"

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
        efinet tftp boot linux normal configfile part_gpt \
        part_msdos fat iso9660 udf ext2 xfs btrfs squash4 \
        gzio all_video video_bochs video_cirrus \
        echo test true regexp probe chain halt reboot \
        search search_fs_file search_fs_uuid search_label \
        minicmd cat ls help
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
    echo "Loading ISO via HTTP memdisk..."
    echo "Note: This may take time depending on ISO size and network speed"
    linux16 /memdisk iso
    initrd16 /iso/${ISO_NAME}
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
  APPEND iso initrd=http://${ALPINE_IP}/iso/${ISO_NAME}

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
# Serves both BIOS (pxelinux.0) and UEFI (bootx64.efi) clients
# ─────────────────────────────────────────────
echo "==> Configuring dnsmasq for TFTP-only mode..."
cat > /etc/dnsmasq.conf <<EOF
# Disable dnsmasq DNS server
port=0

# Enable TFTP server
enable-tftp
tftp-root=${TFTP_ROOT}

# PXE boot – detect client architecture and serve correct bootloader
# Tag UEFI x86-64 clients (client arch 7 = EFI BC, 9 = EFI x86-64)
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-bc,option:client-arch,7

# Serve correct bootloader based on client type
dhcp-boot=tag:efi-x86_64,efi64/bootx64.efi,,${ALPINE_IP}
dhcp-boot=tag:efi-bc,efi64/bootx64.efi,,${ALPINE_IP}
# Use lpxelinux.0 so BIOS clients can fetch HTTP URLs (memdisk + ISO over HTTP).
dhcp-boot=tag:!efi-x86_64,tag:!efi-bc,lpxelinux.0,,${ALPINE_IP}

# Log TFTP requests for debugging
log-dhcp
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
    DOWNLOAD_ISO="yes"
    if [ -f "${ISO_DIR}/${ISO_NAME}" ]; then
        ISO_SIZE=$(du -h "${ISO_DIR}/${ISO_NAME}" | cut -f1)
        echo "==> ISO already exists at ${ISO_DIR}/${ISO_NAME} (${ISO_SIZE})"
        read -r -p "    Download again? [y/N]: " REPLY < /dev/tty || REPLY=""
        case "${REPLY}" in
            [yY]|[yY][eE][sS]) DOWNLOAD_ISO="yes" ;;
            *) DOWNLOAD_ISO="no" ;;
        esac
    fi
    if [ "${DOWNLOAD_ISO}" = "yes" ]; then
        echo "==> Downloading ISO from ${ISO_URL}..."
        wget -O "${ISO_DIR}/${ISO_NAME}" "${ISO_URL}"
    else
        echo "==> Skipping ISO download; using existing file."
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
echo "     Default BIOS     : lpxelinux.0   (HTTP-capable syslinux)"
echo "     Default UEFI     : efi64/bootx64.efi"
echo ""
echo " Client boot files:"
echo "   BIOS clients  → lpxelinux.0       (syslinux w/ HTTP + memdisk)"
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