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

# Create placeholder GRUB config for UEFI clients.
# The real menu entry for the ISO is appended later, after extraction, when
# we know the correct kernel/initrd path and command line for the detected distro.
cat > "${TFTP_ROOT}/efi64/grub/grub.cfg" <<EOF
set timeout=10
set default=0

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
# This is regenerated later, after the ISO has been downloaded and inspected,
# so the entry uses the correct kernel/initrd path and command line for the
# detected distro. The initial version below is just a placeholder that lets
# the menu render even if ISO extraction fails.
# ─────────────────────────────────────────────
echo "==> Creating placeholder BIOS PXE boot menu..."
cat > "${TFTP_ROOT}/pxelinux.cfg/default" <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE PXE Boot Menu (BIOS)

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
        autoindex on;
    }

    # Serve the loop-mounted ISO contents (squashfs, etc.) for live-boot fetch=
    # The ISO is mounted at ${HTTP_ROOT}/iso-contents after download/extraction.
    location /iso-contents/ {
        alias ${HTTP_ROOT}/iso-contents/;
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        client_max_body_size 4G;
        add_header Accept-Ranges bytes;
        autoindex on;
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
# Extract kernel + initrd from the ISO and generate proper boot menu entries.
#
# memdisk-based ISO booting does NOT work for modern Linux installers/live
# images – the BIOS hands off to memdisk, the kernel cannot find a real block
# device, and the machine resets (the "endless loop" symptom).
#
# Instead we loop-mount the ISO, copy its kernel + initrd to the TFTP root,
# and generate an APPEND line with the right cmdline so the installer/live
# system fetches the rest of the ISO from our HTTP server.
# ─────────────────────────────────────────────
ISO_BOOT_DIR="${TFTP_ROOT}/iso-boot"
mkdir -p "${ISO_BOOT_DIR}"

DISTRO=""
KERNEL_REL=""
INITRD_REL=""
EXTRA_CMDLINE=""

if [ -f "${ISO_DIR}/${ISO_NAME}" ]; then
    echo "==> Inspecting ISO to extract kernel and initrd..."
    apk add --quiet xorriso 2>/dev/null || true
    MNT="$(mktemp -d)"
    MOUNTED=0
    if mount -o loop,ro "${ISO_DIR}/${ISO_NAME}" "${MNT}" 2>/dev/null; then
        MOUNTED=1
    else
        echo "    Loop mount unavailable; falling back to xorriso extraction."
    fi

    # Helper: copy a file out of the ISO (whether mounted or via xorriso)
    iso_extract() {
        src="$1"; dst="$2"
        if [ "${MOUNTED}" = "1" ]; then
            if [ -f "${MNT}/${src}" ]; then cp "${MNT}/${src}" "${dst}"; return 0; fi
            return 1
        else
            xorriso -osirrox on -indev "${ISO_DIR}/${ISO_NAME}" \
                -extract "/${src}" "${dst}" >/dev/null 2>&1
            [ -s "${dst}" ]
        fi
    }

    # Detect distro family by probing for well-known files inside the ISO
    probe() {
        if [ "${MOUNTED}" = "1" ]; then [ -e "${MNT}/$1" ]
        else xorriso -indev "${ISO_DIR}/${ISO_NAME}" -find "/$1" >/dev/null 2>&1; fi
    }

    if probe "live/vmlinuz" || probe "live/vmlinuz1"; then
        # Debian Live / Clonezilla / Tails / Kali live ISOs
        DISTRO="debian-live"
        if probe "live/vmlinuz"; then
            iso_extract "live/vmlinuz"   "${ISO_BOOT_DIR}/vmlinuz" || true
        else
            iso_extract "live/vmlinuz1"  "${ISO_BOOT_DIR}/vmlinuz" || true
        fi
        if probe "live/initrd.img"; then
            iso_extract "live/initrd.img"  "${ISO_BOOT_DIR}/initrd" || true
        elif probe "live/initrd1.img"; then
            iso_extract "live/initrd1.img" "${ISO_BOOT_DIR}/initrd" || true
        else
            iso_extract "live/initrd"      "${ISO_BOOT_DIR}/initrd" || true
        fi
        # fetch= URL is finalised later, after the persistent loop-mount attempt.
        # Set a provisional value here; it will be overwritten if mount succeeds.
        KERNEL_REL="iso-boot/vmlinuz"
        INITRD_REL="iso-boot/initrd"
        EXTRA_CMDLINE="boot=live union=overlay fetch=http://${ALPINE_IP}/iso-contents/live/filesystem.squashfs components quiet"
    elif probe "casper/vmlinuz"; then
        # Ubuntu / Linux Mint / Pop!_OS live ISOs
        DISTRO="ubuntu-casper"
        iso_extract "casper/vmlinuz" "${ISO_BOOT_DIR}/vmlinuz" || true
        iso_extract "casper/initrd"  "${ISO_BOOT_DIR}/initrd"  || \
            iso_extract "casper/initrd.lz" "${ISO_BOOT_DIR}/initrd" || true
        KERNEL_REL="iso-boot/vmlinuz"
        INITRD_REL="iso-boot/initrd"
        EXTRA_CMDLINE="boot=casper netboot=url url=http://${ALPINE_IP}/iso/${ISO_NAME} ip=dhcp ---"
    elif probe "install.amd/vmlinuz" || probe "install/vmlinuz"; then
        # Debian installer
        DISTRO="debian-installer"
        if probe "install.amd/vmlinuz"; then
            iso_extract "install.amd/vmlinuz" "${ISO_BOOT_DIR}/vmlinuz" || true
            iso_extract "install.amd/initrd.gz" "${ISO_BOOT_DIR}/initrd" || true
        else
            iso_extract "install/vmlinuz" "${ISO_BOOT_DIR}/vmlinuz" || true
            iso_extract "install/initrd.gz" "${ISO_BOOT_DIR}/initrd" || true
        fi
        KERNEL_REL="iso-boot/vmlinuz"
        INITRD_REL="iso-boot/initrd"
        EXTRA_CMDLINE="auto=true priority=critical url=http://${ALPINE_IP}/preseed.cfg --- quiet"
    elif probe "images/pxeboot/vmlinuz"; then
        # Fedora / RHEL / CentOS / Rocky / Alma (Anaconda)
        DISTRO="anaconda"
        iso_extract "images/pxeboot/vmlinuz" "${ISO_BOOT_DIR}/vmlinuz" || true
        iso_extract "images/pxeboot/initrd.img" "${ISO_BOOT_DIR}/initrd" || true
        KERNEL_REL="iso-boot/vmlinuz"
        INITRD_REL="iso-boot/initrd"
        EXTRA_CMDLINE="inst.repo=http://${ALPINE_IP}/iso/ inst.stage2=hd:LABEL=$(blkid -s LABEL -o value "${ISO_DIR}/${ISO_NAME}" 2>/dev/null || echo CDROM)"
    elif probe "boot/vmlinuz-lts" || probe "boot/vmlinuz-virt"; then
        # Alpine
        DISTRO="alpine"
        if probe "boot/vmlinuz-lts"; then
            iso_extract "boot/vmlinuz-lts" "${ISO_BOOT_DIR}/vmlinuz" || true
            iso_extract "boot/initramfs-lts" "${ISO_BOOT_DIR}/initrd" || true
        else
            iso_extract "boot/vmlinuz-virt" "${ISO_BOOT_DIR}/vmlinuz" || true
            iso_extract "boot/initramfs-virt" "${ISO_BOOT_DIR}/initrd" || true
        fi
        KERNEL_REL="iso-boot/vmlinuz"
        INITRD_REL="iso-boot/initrd"
        EXTRA_CMDLINE="modules=loop,squashfs,sd-mod,usb-storage alpine_repo=http://${ALPINE_IP}/iso/apks modloop=http://${ALPINE_IP}/iso/boot/modloop-lts"
    elif probe "arch/boot/x86_64/vmlinuz-linux"; then
        # Arch Linux
        DISTRO="arch"
        iso_extract "arch/boot/x86_64/vmlinuz-linux" "${ISO_BOOT_DIR}/vmlinuz" || true
        iso_extract "arch/boot/x86_64/initramfs-linux.img" "${ISO_BOOT_DIR}/initrd" || true
        KERNEL_REL="iso-boot/vmlinuz"
        INITRD_REL="iso-boot/initrd"
        ARCHISO_LABEL="$(blkid -s LABEL -o value "${ISO_DIR}/${ISO_NAME}" 2>/dev/null || echo ARCH_$(date +%Y%m))"
        EXTRA_CMDLINE="archisobasedir=arch archiso_http_srv=http://${ALPINE_IP}/iso/ archisolabel=${ARCHISO_LABEL} ip=:::::eth0:dhcp"
    else
        echo "    WARNING: Could not auto-detect distro family inside ISO."
        echo "    Please add a kernel + initrd manually and edit pxelinux.cfg/default."
    fi

    [ "${MOUNTED}" = "1" ] && umount "${MNT}" 2>/dev/null || true
    rmdir "${MNT}" 2>/dev/null || true

    # For Debian Live (Clonezilla etc.) the client fetches the squashfs directly
    # from the server via HTTP. The ISO must therefore be loop-mounted persistently
    # so its internal directory tree (live/filesystem.squashfs, etc.) is visible
    # under a web-accessible path.
    if [ "${DISTRO}" = "debian-live" ]; then
        ISO_CONTENTS="${HTTP_ROOT}/iso-contents"
        mkdir -p "${ISO_CONTENTS}"
        # Unmount first in case a previous run left a stale mount
        umount "${ISO_CONTENTS}" 2>/dev/null || true
        if mount -o loop,ro "${ISO_DIR}/${ISO_NAME}" "${ISO_CONTENTS}"; then
            echo "    ISO loop-mounted at ${ISO_CONTENTS} (served as /iso-contents/)"
            # Update fetch= URL to point at the persistent mount instead of the
            # plain /iso/ dir (which only has the .iso file, not its contents).
            EXTRA_CMDLINE="boot=live union=overlay fetch=http://${ALPINE_IP}/iso-contents/live/filesystem.squashfs components quiet"
        else
            echo "    WARNING: Could not loop-mount ISO. The 'fetch=' URL may fail."
            echo "    Manually run: mount -o loop,ro ${ISO_DIR}/${ISO_NAME} ${ISO_CONTENTS}"
        fi
        # Ensure the mount survives reboots via /etc/fstab
        FSTAB_ENTRY="${ISO_DIR}/${ISO_NAME}  ${ISO_CONTENTS}  iso9660  loop,ro  0 0"
        if ! grep -qF "${ISO_DIR}/${ISO_NAME}" /etc/fstab; then
            echo "${FSTAB_ENTRY}" >> /etc/fstab
            echo "    Added fstab entry for persistent ISO loop-mount."
        fi
    fi

    if [ -n "${KERNEL_REL}" ] && [ -s "${TFTP_ROOT}/${KERNEL_REL}" ] && [ -s "${TFTP_ROOT}/${INITRD_REL}" ]; then
        echo "    Detected distro family: ${DISTRO}"
        echo "    Kernel : ${TFTP_ROOT}/${KERNEL_REL}"
        echo "    Initrd : ${TFTP_ROOT}/${INITRD_REL}"
    else
        echo "    WARNING: kernel/initrd extraction failed; ISO entry will not be added."
        KERNEL_REL=""
    fi
fi

# ─────────────────────────────────────────────
# Regenerate BIOS PXE menu with the real ISO entry (if extraction succeeded)
# ─────────────────────────────────────────────
if [ -n "${KERNEL_REL}" ]; then
    echo "==> Writing final BIOS PXE boot menu..."
    cat > "${TFTP_ROOT}/pxelinux.cfg/default" <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE PXE Boot Menu (BIOS) – ${DISTRO}

LABEL bootiso
  MENU LABEL Boot ${DISTRO} (${ISO_NAME})
  MENU DEFAULT
  KERNEL ${KERNEL_REL}
  INITRD ${INITRD_REL}
  APPEND ${EXTRA_CMDLINE}

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

    echo "==> Adding ISO entry to UEFI GRUB menu..."
    cat > "${TFTP_ROOT}/efi64/grub/grub.cfg" <<EOF
set timeout=10
set default=0

menuentry "Boot ${DISTRO} (${ISO_NAME})" {
    echo "Loading kernel and initrd over TFTP..."
    linux  /${KERNEL_REL} ${EXTRA_CMDLINE}
    initrd /${INITRD_REL}
}

menuentry "Boot from Local Disk" {
    set root=(hd0)
    chainloader +1
}

menuentry "Reboot" { reboot }
menuentry "Shutdown" { halt }
EOF
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