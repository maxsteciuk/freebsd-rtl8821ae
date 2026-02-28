# RTL8821AE Bluetooth on FreeBSD

Comprehensive guide for enabling Bluetooth on systems with the Realtek
RTL8821AE combo WiFi+Bluetooth PCIe card.

## Architecture

The RTL8821AE integrates two controllers on a single chip:

| Function  | Interface | FreeBSD Driver | Protocol Stack              |
|-----------|-----------|----------------|-----------------------------|
| WiFi      | PCIe      | `rtwn(4)`      | net80211 → ifnet            |
| Bluetooth | USB 1.1   | `ng_ubt(4)`    | Netgraph → HCI → L2CAP → Socket |

Even though the card sits in a PCIe slot, the Bluetooth controller connects
to the host via an **internal USB bus**. The two interfaces are completely
independent at the OS level — they use different bus drivers, different
protocol stacks, and can operate simultaneously.

```
                    RTL8821AE Chip
                   ┌──────────────────┐
    PCIe Bus ──────│  WiFi Controller  │──── rtwn(4) ──── net80211
                   │                  │
    Internal USB ──│  BT Controller   │──── ng_ubt(4) ── Netgraph BT
                   └──────────────────┘
```

### Bluetooth Protocol Stack

FreeBSD uses the Netgraph framework for Bluetooth:

```
  USB Device (ubt0)
       │
  ng_ubt ──── HCI transport over USB
       │
  ng_hci ──── Host Controller Interface
       │
  ng_l2cap ── Logical Link Control and Adaptation
       │
  ng_btsocket  BSD socket interface (PF_BLUETOOTH)
```

## Prerequisites

| Component         | Package/Source         | Purpose                        |
|-------------------|-----------------------|--------------------------------|
| `rtlbtfw`         | FreeBSD base system   | Firmware loader utility        |
| `rtlbt-firmware`  | `pkg install`         | Firmware binary files          |
| `ng_ubt.ko`       | FreeBSD base system   | USB Bluetooth kernel driver    |
| `ng_hci.ko`       | FreeBSD base system   | HCI protocol module            |
| `ng_l2cap.ko`     | FreeBSD base system   | L2CAP protocol module          |
| `ng_btsocket.ko`  | FreeBSD base system   | Bluetooth socket interface     |
| `devd`            | FreeBSD base system   | Automatic firmware loading     |

## Quick Setup

```sh
# Install firmware
sudo pkg install rtlbt-firmware

# Run the setup script
sudo sh bluetooth_setup.sh

# Make persistent across reboots
sudo sh bluetooth_setup.sh -p

# Verify everything works
sudo sh bluetooth_test.sh -v
```

## Manual Setup

### Step 1: Install Firmware

```sh
sudo pkg install rtlbt-firmware
```

This installs `rtl8821a_fw.bin` and other Realtek BT firmware files to
`/usr/local/share/rtlbt-firmware/`.

### Step 2: Load Kernel Modules

```sh
sudo kldload ng_ubt
sudo kldload ng_hci
sudo kldload ng_l2cap
sudo kldload ng_btsocket
```

### Step 3: Verify USB Device

```sh
# List USB devices — look for Bluetooth class (0xe0)
usbconfig list
usbconfig dump_device_desc
```

The Bluetooth interface should appear as a USB device. Common identifiers:

| Vendor ID | Product ID | Description                      |
|-----------|------------|----------------------------------|
| 0x0b05    | 0x17dc     | ASUS RTL8821AE Bluetooth         |
| 0x13d3    | 0x3414     | IMC Networks RTL8821AE Bluetooth |
| 0x13d3    | 0x3458     | IMC Networks RTL8821AE Bluetooth |
| 0x13d3    | 0x3461     | IMC Networks RTL8821AE Bluetooth |
| 0x13d3    | 0x3462     | IMC Networks RTL8821AE Bluetooth |

### Step 4: Load Firmware

If `devd` is running with `rtlbtfw.conf`, firmware loading happens
automatically when the USB device attaches. Otherwise, load manually:

```sh
# Find the USB device
usbconfig list

# Load firmware (replace ugenX.Y with actual device)
sudo rtlbtfw -d ugenX.Y -f /usr/local/share/rtlbt-firmware
```

### Step 5: Start the Bluetooth Service

FreeBSD's `/etc/rc.d/bluetooth` script builds the Netgraph stack (HCI, L2CAP,
btsock nodes) and initializes the controller. **You must pass the device name**
— running `service bluetooth start` without a device name will fail with
"Unsupported device:".

```sh
# Start the Bluetooth stack for ubt0
sudo service bluetooth start ubt0
```

This creates the full Netgraph topology:

```
ubt0 ─── ubt0hci ─── ubt0l2cap ─── btsock_l2c
              │                  └── btsock_l2c_raw
              └── btsock_hci_raw
```

To stop:

```sh
sudo service bluetooth stop ubt0
```

### Step 6: Verify Bluetooth Stack

```sh
# Check Netgraph nodes — ubt0 should have 1 hook, ubt0hci and ubt0l2cap 3 each
sudo ngctl list

# Example output when operational:
#   Name: ubt0       Type: ubt    ID: 00000005   Num hooks: 1
#   Name: ubt0hci    Type: hci    ID: 0000000b   Num hooks: 3
#   Name: ubt0l2cap  Type: l2cap  ID: 0000000f   Num hooks: 3

# Read HCI BD address
sudo hccontrol -n ubt0hci read_bd_addr
```

### Step 7: Persistent Configuration

Add to `/boot/loader.conf`:

```
ng_ubt_load="YES"
ng_hci_load="YES"
ng_l2cap_load="YES"
ng_btsocket_load="YES"
```

Ensure `devd` is enabled in `/etc/rc.conf`:

```
devd_enable="YES"
```

## How Firmware Loading Works

The RTL8821AE Bluetooth controller starts in "bootloader mode" with
`lmp_subversion = 0x8821`. In this state, the standard Bluetooth HCI stack
cannot communicate with it — attempting to do so will lock the adapter,
requiring a power cycle.

FreeBSD handles this with a two-stage process:

1. **`ng_ubt_rtl`** probes the device, reads `lmp_subversion`, and if it
   matches `0x8821` (bootloader mode), returns `ENXIO` — blocking the
   standard `ng_ubt` driver from attaching.

2. **`devd`** detects the USB device and runs `rtlbtfw`, which:
   - Reads the ROM version via HCI vendor command `0xfc6d`
   - Selects the correct firmware file (`rtl8821a_fw.bin`)
   - Parses the epatch firmware (v1 format, "Realtech" signature)
   - Downloads the firmware in 252-byte segments via HCI vendor command `0xfc20`
   - After successful download, the device re-enumerates with a new
     `lmp_subversion`, and `ng_ubt_rtl` allows attachment.

```
  Boot
   │
   ├─ USB device detected (bootloader mode, lmp_subversion=0x8821)
   │   └─ ng_ubt_rtl: probe → ENXIO (blocked)
   │
   ├─ devd triggers rtlbtfw
   │   └─ Firmware downloaded via HCI 0xfc20
   │
   ├─ Device re-enumerates (operational mode)
   │   └─ ng_ubt_rtl: probe → BUS_PROBE_DEFAULT (allowed)
   │
   └─ ng_ubt: attach → Netgraph ubt node created
```

## WiFi + Bluetooth Coexistence

Both WiFi and Bluetooth operate simultaneously without interference:

- **WiFi** uses the PCIe bus (`rtwn0` interface via `if_rtwn_pci`)
- **Bluetooth** uses the internal USB bus (`ubt0` Netgraph node via `ng_ubt`)

The RTL8821AE chip has internal coexistence logic that coordinates 2.4 GHz
radio sharing between WiFi and Bluetooth (TDMA-based coexistence). This is
handled in hardware/firmware — no driver-level coordination is needed.

To use both simultaneously:

```sh
# WiFi
sudo ifconfig wlan0 create wlandev rtwn0
sudo ifconfig wlan0 up scan

# Bluetooth
sudo hccontrol -n ubt0hci read_bd_addr
```

## Troubleshooting

### Bluetooth USB device not detected

1. Verify the card is installed: `pciconf -lv | grep -A4 8821`
2. Check USB controllers: `usbconfig list`
3. Some BIOS settings disable the USB interface — check BIOS
4. Try: `usbconfig -d ugenX.Y reset`

### Firmware loading fails

1. Ensure firmware is installed: `ls /usr/local/share/rtlbt-firmware/rtl8821a_fw.bin`
2. Check devd log: `grep rtlbtfw /var/log/messages`
3. Manual load: `rtlbtfw -D -d ugenX.Y -f /usr/local/share/rtlbt-firmware`
4. If adapter is locked, power cycle the system (not just reboot)

### "Unable to setup Bluetooth stack for device ubt0"

This usually means the Netgraph stack is in a stale half-initialized state
(e.g. from a previous failed start). The `ubt0` node exists but its hooks
are disconnected, so `mkpeer`/`connect` commands silently fail.

Fix by stopping first, then starting:

```sh
sudo service bluetooth stop ubt0
sudo service bluetooth start ubt0
```

If that doesn't work, manually clean up the Netgraph nodes:

```sh
sudo ngctl shutdown ubt0l2cap: 2>/dev/null
sudo ngctl shutdown ubt0hci: 2>/dev/null
sudo service bluetooth start ubt0
```


### No Netgraph ubt node after firmware loading

1. Check: `kldstat | grep ng_ubt`
2. The device may need to re-enumerate: `usbconfig -d ugenX.Y reset`
3. Check dmesg: `dmesg | grep -i ubt`

### Bluetooth works but WiFi doesn't (or vice versa)

These are independent subsystems. Debug each one separately:
- WiFi: see main README.md
- Bluetooth: follow the steps in this document

### Module loading fails at boot

If modules fail to load at boot, check:
1. Modules exist: `ls /boot/kernel/ng_ubt.ko`
2. Dependencies satisfied: `kldstat`
3. No typos in loader.conf entries

## References

- `ng_ubt(4)` — FreeBSD USB Bluetooth driver man page
- `ng_hci(4)` — HCI Netgraph node man page
- `rtlbtfw(8)` — Realtek Bluetooth firmware loader man page
- `hccontrol(8)` — Bluetooth HCI control utility
- `ngctl(8)` — Netgraph control utility
- FreeBSD Handbook, Chapter 31.5 — Bluetooth
- Linux `btrtl.c` — Reference implementation for Realtek BT firmware loading
