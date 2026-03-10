# PXE Boot Server on Alpine Linux

An automated setup script to configure a PXE boot server on Alpine Linux.  
DHCP is handled externally by an OPNsense router — this server provides **TFTP** (boot files) and **HTTP** (ISO serving) only.  
Supports both **BIOS** (syslinux/pxelinux) and **UEFI** (grub-efi) clients.

---

## Architecture Overview

```
Client PC (PXE boot)
       │
       ├── BIOS client ──────────────────────────┐
       └── UEFI client ──────────────────────────┤
                                                  ▼
                                    OPNsense Router (DHCP)
                                      → IP address
                                      → Next Server = Alpine IP
                                      → BIOS boot file  = pxelinux.0
                                      → UEFI boot file  = efi64/bootx64.efi
                                                  │
                                                  ▼
                                    Alpine Linux PXE Server
                                      ├── dnsmasq  (TFTP) :69
                                      │     ├── pxelinux.0       (BIOS)
                                      │     └── efi64/bootx64.efi (UEFI)
                                      └── nginx    (HTTP) :80
                                            └── /iso/boot.iso
```

---

## Prerequisites

- A machine running a **fresh Alpine Linux** installation
- Network access from the Alpine machine to download packages
- An **OPNsense** router managing DHCP on the same network segment
- The Alpine server must have a **static IP address**

---

## 1. Prepare Alpine Linux

If you haven't already, set a static IP on Alpine:

```bash
vi /etc/network/interfaces
```

Example static config:

```
auto eth0
iface eth0 inet static
    address 192.168.1.10
    netmask 255.255.255.0
    gateway 192.168.1.1
```

Apply it:

```bash
service networking restart
```

---

## 2. Configure the Script

Edit the variables at the top of [`setupnetboot.sh`](setupnetboot.sh) before running:

```bash
ALPINE_IP="192.168.1.10"                    # Static IP of this Alpine server
ISO_URL="https://example.com/your.iso"      # URL to download the ISO
ISO_NAME="boot.iso"                         # Filename to save the ISO as
```

> **Tip:** If you want to place the ISO manually instead of downloading it,  
> set `ISO_URL=""` and copy your ISO to `/srv/http/iso/` after running the script.

---

## 3. Run the Setup Script

Transfer the script to your Alpine machine and run it as root:

```bash
chmod +x setupnetboot.sh
./setupnetboot.sh
```

The script will automatically:

- Install `dnsmasq`, `syslinux`, `grub-efi`, `nginx`, `wget`
- Configure TFTP to serve **BIOS** (`pxelinux.0`) and **UEFI** (`bootx64.efi`) boot files
- Build a standalone GRUB EFI image for UEFI clients (with fallback handling)
- Configure Nginx to serve the ISO over HTTP
- Download the ISO (if `ISO_URL` is set)
- Enable and start all services

---

## 4. Configure OPNsense

In your OPNsense router, navigate to:

**Services → DHCPv4 → [Your LAN Interface] → Network Booting**

| Setting | Value |
|---|---|
| Enable Network Booting | ✅ Checked |
| Next Server | `192.168.1.10` *(your Alpine IP)* |
| Default BIOS filename | `pxelinux.0` |
| Default UEFI filename | `efi64/bootx64.efi` |

> **How it works:** dnsmasq on the Alpine server detects the client architecture via DHCP option 93.  
> UEFI clients (arch `7` or `9`) receive `efi64/bootx64.efi`; all others receive `pxelinux.0`.

Save and apply the changes.

---

## 5. Boot a Client

1. On the client PC, enter the BIOS/UEFI settings
2. Set **Network/PXE Boot** as the first boot device
3. **For UEFI clients:** Disable **Secure Boot** (our GRUB image is not signed)
4. Save and reboot
5. The client will receive DHCP from OPNsense, then load the appropriate bootloader from Alpine:
   - **BIOS** → syslinux menu → Boot ISO via memdisk
   - **UEFI** → GRUB menu → Boot ISO via memdisk
6. Select **"Boot from ISO"** in the menu

---

## Directory Structure

After setup, the server will have the following layout:

```
/srv/
├── tftp/                        # TFTP root (served by dnsmasq)
│   ├── pxelinux.0               # BIOS PXE bootloader (syslinux)
│   ├── bootx64.efi              # UEFI bootloader copy (root level)
│   ├── memdisk                  # Memory disk loader
│   ├── ldlinux.c32
│   ├── libcom32.c32
│   ├── libutil.c32
│   ├── menu.c32
│   ├── vesamenu.c32
│   ├── pxelinux.cfg/
│   │   └── default              # BIOS boot menu (syslinux)
│   └── efi64/
│       ├── bootx64.efi          # UEFI GRUB EFI image
│       └── grub/
│           └── grub.cfg         # UEFI GRUB boot menu
└── http/                        # HTTP root (served by nginx)
    └── iso/
        └── boot.iso             # Your ISO file
```

---

## Troubleshooting

### Client doesn't receive a PXE boot offer
- Verify OPNsense **Network Booting** is enabled and pointing to the correct Alpine IP
- Confirm both BIOS and UEFI filenames are set in OPNsense
- Check the Alpine server firewall allows UDP `69` (TFTP) and TCP `80` (HTTP)

### GRUB EFI build fails
If you see `grub-mkimage: error: cannot open '/usr/lib/grub/x86_64-efi/linuxefi.mod'`:

```bash
# Check available GRUB modules
ls /usr/lib/grub/x86_64-efi/

# The script will automatically fall back to using existing EFI files
# BIOS boot will still work normally
```

### TFTP times out
```bash
# Check dnsmasq is running
rc-service dnsmasq status

# Watch live TFTP requests
tail -f /var/log/messages

# Test TFTP manually
apk add tftp-hpa
tftp 192.168.1.10
> get pxelinux.0
> quit
```

### UEFI client gets wrong bootloader or hangs
```bash
# Verify dnsmasq is matching client architecture correctly
grep -i "arch\|efi\|pxe" /var/log/messages

# Check if UEFI bootloader exists
ls -la /srv/tftp/efi64/bootx64.efi

# Disable Secure Boot on the client if enabled
```

### ISO not found / HTTP 404
```bash
# Check nginx is running
rc-service nginx status

# Verify the ISO exists and is readable
ls -lh /srv/http/iso/

# Test HTTP access from another machine
curl -I http://192.168.1.10/iso/boot.iso
```

### Large ISO takes too long to boot
For ISOs larger than 1GB, consider these alternatives:

```bash
# Extract kernel and initrd from the ISO instead of using memdisk
mkdir /mnt/iso
mount -o loop /srv/http/iso/boot.iso /mnt/iso
cp /mnt/iso/casper/vmlinuz /srv/tftp/
cp /mnt/iso/casper/initrd /srv/tftp/
umount /mnt/iso
```

Then update the boot menu to use direct kernel/initrd loading instead of memdisk.

### Restart services manually
```bash
rc-service dnsmasq restart
rc-service nginx restart
```

---

## Notes

- **Both BIOS and UEFI clients** use `memdisk` to load the ISO entirely into RAM — best for **ISOs under 2GB**.
- **UEFI Secure Boot is not supported** — you must disable Secure Boot in client firmware settings.
- For **large OS installer ISOs** (>2GB), extract the kernel/initrd and boot directly instead of using memdisk.
- The script includes fallback handling if GRUB EFI modules are incompatible.
- The script uses `set -e` and will stop on any error — check the output carefully if it fails.
- Both bootloaders serve identical functionality; the choice depends on client firmware (BIOS vs UEFI).