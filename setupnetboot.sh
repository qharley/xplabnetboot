#!/bin/bash
set -e

# ─────────────────────────────────────────────
# Configuration – edit these before running
# ─────────────────────────────────────────────
ALPINE_IP="192.168.1.10"          # IP of this Alpine PXE server
ISO_URL="https://example.com/your.iso"   # URL to download the ISO (or leave blank to copy manually)
ISO_NAME="boot.iso"               # Filename for the ISO
TFTP_ROOT="/srv/tftp"
HTTP_ROOT="/srv/http"
ISO_DIR="${HTTP_ROOT}/iso"

# ─────────────────────────────────────────────
# Install required packages
# ─────────────────────────────────────────────
echo "==> Updating apk and installing packages..."
apk update
apk add dnsmasq syslinux nginx wget curl bash

# ─────────────────────────────────────────────
# Set up TFTP directory structure
# ─────────────────────────────────────────────
echo "==> Setting up TFTP root at ${TFTP_ROOT}..."
mkdir -p "${TFTP_ROOT}/pxelinux.cfg"
mkdir -p "${TFTP_ROOT}/efi64"

# Copy PXE bootloaders from syslinux
cp /usr/share/syslinux/pxelinux.0       "${TFTP_ROOT}/"
cp /usr/share/syslinux/ldlinux.c32      "${TFTP_ROOT}/"
cp /usr/share/syslinux/libcom32.c32     "${TFTP_ROOT}/"
cp /usr/share/syslinux/libutil.c32      "${TFTP_ROOT}/"
cp /usr/share/syslinux/menu.c32         "${TFTP_ROOT}/"
cp /usr/share/syslinux/vesamenu.c32     "${TFTP_ROOT}/" 2>/dev/null || true

# ─────────────────────────────────────────────
# Create PXE boot menu (BIOS)
# ─────────────────────────────────────────────
echo "==> Creating PXE boot menu..."
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
# ─────────────────────────────────────────────
echo "==> Configuring dnsmasq for TFTP-only mode..."
cat > /etc/dnsmasq.conf <<EOF
# Disable dnsmasq DNS server
port=0

# Enable TFTP server
enable-tftp
tftp-root=${TFTP_ROOT}

# PXE boot file for BIOS clients
dhcp-boot=pxelinux.0,,${ALPINE_IP}

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
# OPNsense reminder
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
echo "     Enable          : ✔"
echo "     Next Server     : ${ALPINE_IP}"
echo "     Default BIOS    : pxelinux.0"
echo ""