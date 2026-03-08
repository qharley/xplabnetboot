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
- Build a standalone GRUB EFI image for UEFI clients
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
3. Save and reboot
4. The client will receive DHCP from OPNsense, then load the appropriate bootloader from Alpine:
   - **BIOS** → syslinux menu → Boot ISO via memdisk
   - **UEFI** → GRUB menu → Boot ISO
5. Select **"Boot from ISO"** in the menu

---

## Directory Structure

After setup, the server will have the following layout:

```
/srv/
├── tftp/                        # TFTP root (served by dnsmasq)
│   ├── pxelinux.0               # BIOS PXE bootloader (syslinux)
│   ├── bootx64.efi              # UEFI bootloader copy (root level)
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

### TFTP times out
```bash
# Check dnsmasq is running
rc-service dnsmasq status

# Watch live TFTP requests
tail -f /var/log/messages
```

### UEFI client gets wrong bootloader
```bash
# Verify dnsmasq is matching client architecture correctly
# Look for "client-arch" in logs
grep -i "arch\|efi\|pxe" /var/log/messages
```

### ISO not found / HTTP 404
```bash
# Check nginx is running
rc-service nginx status

# Verify the ISO exists
ls -lh /srv/http/iso/

# Test HTTP access from another machine
curl -I http://192.168.1.10/iso/boot.iso
```

### Restart services manually
```bash
rc-service dnsmasq restart
rc-service nginx restart
```

---

## Notes

- **BIOS clients** use `syslinux/memdisk` to load the ISO entirely into RAM — best for **small ISOs**.
- **UEFI clients** use `grub-efi` which offers better compatibility with modern hardware.
- For **large OS installer ISOs**, consider extracting the `kernel` + `initrd` from the ISO and booting those directly instead of using memdisk.
- The script uses `set -e` and will stop on any error — check the output carefully if it fails.
- UEFI Secure Boot is **not supported** — you may need to disable Secure Boot in the client's firmware settings.