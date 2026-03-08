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
echo "==> Copying BIOS syslinux bootloaders..."
cp /usr/share/syslinux/pxelinux.0       "${TFTP_ROOT}/"
cp /usr/share/syslinux/ldlinux.c32      "${TFTP_ROOT}/"
cp /usr/share/syslinux/libcom32.c32     "${TFTP_ROOT}/"
cp /usr/share/syslinux/libutil.c32      "${TFTP_ROOT}/"
cp /usr/share/syslinux/menu.c32         "${TFTP_ROOT}/"
cp /usr/share/syslinux/vesamenu.c32     "${TFTP_ROOT}/" 2>/dev/null || true

# ─────────────────────────────────────────────
# Set up UEFI GRUB bootloader
# ─────────────────────────────────────────────
echo "==> Setting up UEFI GRUB bootloader..."

# Build a standalone GRUB EFI image that includes the TFTP fetch config
grub-mkimage \
    --format=x86_64-efi \
    --output="${TFTP_ROOT}/efi64/bootx64.efi" \
    --prefix="(tftp,${ALPINE_IP})/efi64/grub" \
    efinet tftp boot linux linuxefi normal configfile part_gpt \
    part_msdos fat iso9660 udf ext2 xfs btrfs squash4 \
    gzio all_video video_bochs video_cirrus \
    echo test true regexp probe

# Create GRUB config for UEFI clients
cat > "${TFTP_ROOT}/efi64/grub/grub.cfg" <<EOF
set timeout=10
set default=0

menuentry "Boot from ISO (${ISO_NAME})" {
    echo "Loading ISO via HTTP..."
    linuxefi /vmlinuz root=/dev/ram0 ip=dhcp
    initrdefi /initrd.img
}

menuentry "Boot from Local Disk" {
    exit
}
EOF

# Also place bootx64.efi at the root for simpler DHCP filename config
cp "${TFTP_ROOT}/efi64/bootx64.efi" "${TFTP_ROOT}/bootx64.efi"

# ─────────────────────────────────────────────
# Create PXE boot menu (BIOS / syslinux)
# ─────────────────────────────────────────────
echo "==> Creating BIOS PXE boot menu..."
cat > "${TFTP_ROOT}/pxelinux.cfg/default" <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE PXE Boot Menu

LABEL bootiso
  MENU LABEL Boot from ISO (${ISO_NAME})
  KERNEL memdisk
  APPEND iso initrd=http://${ALPINE_IP}/iso/${ISO_NAME}

LABEL local
  MENU LABEL Boot from Local Disk
  LOCALBOOT 0
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

# Serve correct bootloader based on client type
dhcp-boot=tag:efi-x86_64,efi64/bootx64.efi,,${ALPINE_IP}
dhcp-boot=tag:!efi-x86_64,pxelinux.0,,${ALPINE_IP}

# Log TFTP requests
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

    location /iso/ {
        alias ${ISO_DIR}/;
        sendfile on;
        tcp_nopush on;
    }
}
EOF

# Remove default nginx site if present
rm -f /etc/nginx/http.d/default.conf

# ─────────────────────────────────────────────
# Download or remind user to place the ISO
# ─────────────────────────────────────────────
if [ -n "${ISO_URL}" ]; then
    echo "==> Downloading ISO from ${ISO_URL}..."
    wget -O "${ISO_DIR}/${ISO_NAME}" "${ISO_URL}"
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
echo "   BIOS clients  → pxelinux.0      (syslinux)"
echo "   UEFI clients  → efi64/bootx64.efi (grub-efi)"
echo ""