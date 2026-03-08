# PXE Boot Server on Alpine Linux

A automated setup script to configure a PXE boot server on Alpine Linux.  
DHCP is handled externally by an OPNsense router — this server provides **TFTP** (boot files) and **HTTP** (ISO serving) only.

---

## Architecture Overview

```
Client PC (PXE boot)
       │
       ▼
OPNsense Router (DHCP)
  → sends IP + Next Server = Alpine IP
  → sends boot filename = pxelinux.0
       │
       ▼
Alpine Linux PXE Server
  ├── dnsmasq  (TFTP)  :69   → serves pxelinux.0 + boot menu
  └── nginx    (HTTP)  :80   → serves ISO file
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
# Edit the network interface config
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

Edit the variables at the top of `setupnetboot.sh` before running:

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
# Make it executable
chmod +x setupnetboot.sh

# Run as root
./setupnetboot.sh
```

The script will automatically:

- Install `dnsmasq`, `syslinux`, `nginx`, `wget`
- Configure TFTP to serve PXE boot files
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

Save and apply the changes.

---

## 5. Boot a Client

1. On the client PC, enter the BIOS/UEFI settings
2. Set **Network/PXE Boot** as the first boot device
3. Save and reboot
4. The client will receive DHCP from OPNsense, then load the PXE menu from Alpine
5. Select **"Boot from ISO"** in the menu

---

## Directory Structure

After setup, the server will have the following layout:

```
/srv/
├── tftp/                    # TFTP root (served by dnsmasq)
│   ├── pxelinux.0           # BIOS PXE bootloader
│   ├── ldlinux.c32
│   ├── libcom32.c32
│   ├── libutil.c32
│   ├── menu.c32
│   ├── vesamenu.c32
│   └── pxelinux.cfg/
│       └── default          # Boot menu configuration
└── http/                    # HTTP root (served by nginx)
    └── iso/
        └── boot.iso         # Your ISO file
```

---

## Troubleshooting

### Client doesn't get PXE boot offer
- Verify OPNsense **Network Booting** is enabled and pointing to the correct Alpine IP
- Confirm the Alpine server's firewall allows UDP port `69` (TFTP) and TCP port `80` (HTTP)

### TFTP times out
```bash
# Check dnsmasq is running
rc-service dnsmasq status

# Check logs
tail -f /var/log/messages
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

- **UEFI boot** is not configured by default. UEFI clients require additional EFI bootloaders (e.g., from `grub-efi`).
- Booting via `memdisk` loads the entire ISO into RAM. This works best for **small ISOs** (rescue tools, memtest, etc.). For large OS installers, consider extracting the `kernel` + `initrd` from the ISO directly.
- The script uses `set -e`, so it will stop on any error. Check the output carefully