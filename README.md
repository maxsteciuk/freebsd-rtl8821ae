# RTL8821AE / RTL8812AE WiFi + Bluetooth Driver for FreeBSD

FreeBSD support for Realtek RTL8821AE and RTL8812AE:

- **802.11ac WiFi** — PCIe kernel driver extending the [rtwn(4)](https://man.freebsd.org/cgi/man.cgi?query=rtwn&sektion=4&manpath=freebsd-current) framework
- **Bluetooth 4.0** — setup automation for the [ng_ubt(4)](https://man.freebsd.org/cgi/man.cgi?query=ng_ubt&sektion=4&manpath=freebsd-current) / [rtlbtfw(8)](https://man.freebsd.org/cgi/man.cgi?query=rtlbtfw&sektion=8&manpath=freebsd-current) stack
  (RTL8821AE only; RTL8812AE is WiFi-only)

## Supported Devices

The RTL8821AE is a combo WiFi+Bluetooth chip. WiFi uses a PCIe interface;
Bluetooth uses an internal USB 1.1 interface. Both can operate simultaneously.
The RTL8812AE is WiFi-only (2x2 MIMO, no Bluetooth).

### WiFi — PCIe Device IDs

The [rtwn(4)](https://man.freebsd.org/cgi/man.cgi?query=rtwn&sektion=4&manpath=freebsd-current) driver matches on the primary PCI vendor/device ID (subsystem
IDs are not checked, so all OEM cards with these chips are supported):

| Vendor ID | Device ID | Chipset     | Streams | Bluetooth |
|-----------|-----------|-------------|---------|-----------|
| 0x10ec    | 0x8821    | RTL8821AE   | 1x1     | Yes (USB) |
| 0x10ec    | 0x8812    | RTL8812AE   | 2x2     | No        |

### Known OEM WiFi Modules

These cards have been reported working or are expected to work:

| Subvendor | Subdevice | OEM Module              | Chipset   | Form Factor    |
|-----------|-----------|-------------------------|-----------|----------------|
| 0x1a3b    | 0x216c    | AzureWave AW-CB161H     | RTL8821AE | Half Mini PCIe |
| 0x1a3b    | 0x2161    | AzureWave AW-CB161H     | RTL8821AE | Half Mini PCIe |
| 0x1043    | 0x85b4    | ASUS                    | RTL8821AE | Half Mini PCIe |
| 0x1043    | 0x207f    | ASUS                    | RTL8821AE | Half Mini PCIe |
| 0x1043    | 0x210c    | ASUS                    | RTL8821AE | Half Mini PCIe |
| 0x17aa    | 0xa814    | Lenovo                  | RTL8821AE | Half Mini PCIe |
| 0x10ec    | 0x8821    | Realtek reference       | RTL8821AE | —              |
| 0x1043    | 0x8812    | ASUS PCE-AC56/PCE-AC51  | RTL8812AE | PCIe x1        |
| 0x2357    | 0x0112    | TP-Link Archer T4E      | RTL8812AE | PCIe x1        |
| 0x1186    | 0x3318    | D-Link DWA-582          | RTL8812AE | PCIe x1        |
| 0x10ec    | 0x8812    | Realtek reference       | RTL8812AE | —              |

> **Note:** The driver does not filter on subsystem IDs. Any card with primary
> PCI ID `10ec:8821` or `10ec:8812` will be recognized.

### Bluetooth — USB Device IDs

The Bluetooth controller on RTL8821AE combo modules appears as a separate USB
device. FreeBSD's `ng_ubt_rtl(4)` driver handles firmware loading; [ng_ubt(4)](https://man.freebsd.org/cgi/man.cgi?query=ng_ubt&sektion=4&manpath=freebsd-current)
provides the Bluetooth HCI transport. The following USB device IDs are
registered in the FreeBSD kernel for RTL8821AE Bluetooth:

| USB Vendor | USB Product | OEM                    | Notes                  |
|------------|-------------|------------------------|------------------------|
| 0x0b05     | 0x17dc      | ASUSTek Computer       | ASUS-branded modules   |
| 0x13d3     | 0x3414      | IMC Networks/AzureWave |                        |
| 0x13d3     | 0x3458      | IMC Networks/AzureWave |                        |
| 0x13d3     | 0x3461      | IMC Networks/AzureWave |                        |
| 0x13d3     | 0x3462      | IMC Networks/AzureWave | Verified on this repo  |

> **Note:** `ng_ubt_rtl(4)` also has a generic Realtek Bluetooth class match.
> Realtek BT USB devices not in the table above may still be detected
> automatically via USB class/subclass/protocol matching.

## Features

### WiFi (PCIe — [rtwn(4)](https://man.freebsd.org/cgi/man.cgi?query=rtwn&sektion=4&manpath=freebsd-current))

- 802.11ac (VHT) with 80 MHz channel width
- 2.4 GHz and 5 GHz dual-band
- HT40 and Short GI
- LDPC, STBC
- Hardware encryption offload
- RX checksum offload (IPv4 + IPv6)
- Firmware-assisted operation
- Power management

### Bluetooth 4.0 (USB — [ng_ubt(4)](https://man.freebsd.org/cgi/man.cgi?query=ng_ubt&sektion=4&manpath=freebsd-current))

- Bluetooth Core Specification v4.0
- Dual mode: BR/EDR + Low Energy (BLE)
- Uses internal USB 1.1 interface (separate from WiFi PCIe)
- Automatic firmware loading via `devd` + `rtlbtfw`
- Netgraph-based stack: HCI → L2CAP → Bluetooth sockets
- Simultaneous WiFi + Bluetooth operation

## Tested On

- FreeBSD 15.0-RELEASE (version 1500068)

## Repository Layout

```
sys/
├── dev/rtwn/
│   ├── pci/
│   │   └── rtwn_pci_attach.h          ← Modified: added RTL8821AE/RTL8812AE device IDs
│   └── rtl8821a/pci/
│       ├── r21a_pci_attach.c           ← New: PCI attachment, callbacks, scan/post-init
│       ├── r21a_pci_attach.h           ← New: function prototypes
│       ├── r21a_pci_compat.c           ← New: compat wrappers (vap_preattach, TX desc, etc.)
│       └── r21ae_tx_desc.h             ← New: PCIe TX descriptor layout (40-byte SW + DMA)
├── contrib/dev/rtwn/
│   └── rtwn-rtl8821aefw.fw.uu          ← Firmware (uuencoded)
└── modules/
    ├── rtwn_pci/
    │   └── Makefile                    ← Modified: added r12a/r21a/r88e/r92c sources
    └── rtwnfw/
        ├── Makefile                    ← Modified: added rtwnrtl8821ae subdir
        └── rtwnrtl8821ae/
            └── Makefile                ← New: firmware kernel module build
bluetooth_setup.sh                       ← New: Bluetooth setup automation
bluetooth_test.sh                        ← New: Bluetooth test suite
BLUETOOTH.md                             ← New: Bluetooth documentation
```

## Quick Install

```sh
# Clone this repo
git clone https://github.com/maxsteciuk/freebsd-rtl8821ae.git
cd freebsd-rtl8821ae

# Install WiFi driver only (default, as root)
sudo sh install.sh

# Install WiFi + Bluetooth
sudo sh install.sh --all

# Install Bluetooth only
sudo sh install.sh --bluetooth
```

## Manual Install

### 1. Copy driver source files

```sh
# New PCI driver files
sudo mkdir -p /usr/src/sys/dev/rtwn/rtl8821a/pci
sudo cp sys/dev/rtwn/rtl8821a/pci/* /usr/src/sys/dev/rtwn/rtl8821a/pci/

# Modified PCI attach header (adds device IDs for 8821AE/8812AE)
sudo cp sys/dev/rtwn/pci/rtwn_pci_attach.h /usr/src/sys/dev/rtwn/pci/
```

### 2. Copy Makefiles

```sh
# Module Makefile (adds r12a/r21a/r88e sources to the build)
sudo cp sys/modules/rtwn_pci/Makefile /usr/src/sys/modules/rtwn_pci/

# Firmware module
sudo mkdir -p /usr/src/sys/modules/rtwnfw/rtwnrtl8821ae
sudo cp sys/modules/rtwnfw/rtwnrtl8821ae/Makefile /usr/src/sys/modules/rtwnfw/rtwnrtl8821ae/
sudo cp sys/modules/rtwnfw/Makefile /usr/src/sys/modules/rtwnfw/
```

### 3. Install firmware

```sh
sudo mkdir -p /usr/src/sys/contrib/dev/rtwn
sudo cp sys/contrib/dev/rtwn/rtwn-rtl8821aefw.fw.uu /usr/src/sys/contrib/dev/rtwn/
```

### 4. Build and install

```sh
cd /usr/src

# Build the driver module
make -C sys/modules/rtwn_pci clean all
sudo make -C sys/modules/rtwn_pci install

# Build and install the firmware module
make -C sys/modules/rtwnfw/rtwnrtl8821ae clean all
sudo make -C sys/modules/rtwnfw/rtwnrtl8821ae install
```

### 5. Load and test

```sh
# Load modules
sudo kldload rtwn-rtl8821aefw
sudo kldload if_rtwn_pci

# Create wireless interface
sudo ifconfig wlan0 create wlandev rtwn0
sudo ifconfig wlan0 up
sudo ifconfig wlan0 list scan
```

### 6. Make persistent across reboots

Add to `/boot/loader.conf`:

```
rtwn-rtl8821aefw_load="YES"
if_rtwn_pci_load="YES"
```

## Integrating with Future FreeBSD Releases

When a new FreeBSD release comes out:

1. **Check if upstream already includes RTL8821AE PCIe support.** Look for
   `sys/dev/rtwn/rtl8821a/pci/` in the source tree. If present, this repo
   is no longer needed.

2. **If not included**, copy the files from this repo into the new source
   tree following the same paths. The key changes are:

   - **New files** in `sys/dev/rtwn/rtl8821a/pci/` — just copy them
   - **`sys/dev/rtwn/pci/rtwn_pci_attach.h`** — add the `RTWN_CHIP_RTL8821AE`
     enum entry, device table entries for 0x8821 and 0x8812, the
     `r21a_pci_attach` function pointer, and its prototype
   - **`sys/modules/rtwn_pci/Makefile`** — add `.PATH` and `SRCS` lines for
     r12a, r21a, r88e, and r92c sources
   - **`sys/modules/rtwnfw/Makefile`** — add `rtwnrtl8821ae` to `SUBDIR`

3. Rebuild as described in the Manual Install section above.

## Bluetooth Setup

The RTL8821AE includes a Bluetooth 4.0 controller accessible via an internal
USB 1.1 interface. FreeBSD's base system already includes the kernel driver
(`ng_ubt_rtl`) and firmware loader (`rtlbtfw`). You only need to install the
firmware files and load the modules.

### Quick Bluetooth Setup

```sh
# Install Bluetooth firmware
sudo pkg install rtlbt-firmware

# Run the setup script
sudo sh bluetooth_setup.sh -p

# Verify
sudo sh bluetooth_test.sh -v
```

For detailed Bluetooth documentation including architecture, troubleshooting,
and WiFi+BT coexistence information, see **[BLUETOOTH.md](BLUETOOTH.md)**.

## Technical Notes

### Bug Fixes Included

These critical bugs were found and fixed during development:

- **Interrupt register mismatch** — RTL8821AE uses interrupt registers at
  0x0B0 (R88E_HIMR), not 0x120 (R92C_HIMR). Using wrong offsets caused an
  interrupt storm and system hang on `ifconfig up`.

- **`sc_post_init` type mismatch** — `r92ce_post_init` casts `sc_priv` to
  `struct r92c_softc` but RTL8821AE uses `struct r12a_softc`. This corrupted
  kernel callout structures causing an immediate panic.

- **`r92c_scan_start/end` struct mismatch** — These functions read
  `rs_scan_start` at offset 0x70 (`r92c_softc`), but the actual field lives
  at offset 0x190 (`r12a_softc`). Reading NULL → page fault → kernel panic.

- **TX descriptor layout** — RTL8821AE uses 10 software DWORDs (40 bytes)
  before PCI DMA fields, not 7 DWORDs like RTL8192CE. Wrong offsets caused
  DMA corruption.

- **C2H report classification** — RTL8821AE delivers firmware C2H reports
  through the RX ring (flagged with `R12A_RXDW2_RPT_C2H`), unlike RTL8192C
  which uses a register. Without proper classification, TX status reports
  were lost.

## License

BSD 2-Clause — see individual file headers for details.
