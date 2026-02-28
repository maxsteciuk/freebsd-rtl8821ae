# Copilot Instructions — FreeBSD RTL8821AE WiFi Driver

## Build Commands

```sh
# Build the rtwn_pci kernel module (requires FreeBSD source tree at /usr/src)
make -C sys/modules/rtwn_pci clean all
sudo make -C sys/modules/rtwn_pci install

# Build the firmware module
make -C sys/modules/rtwnfw/rtwnrtl8821ae clean all
sudo make -C sys/modules/rtwnfw/rtwnrtl8821ae install

# Load modules
sudo kldload rtwn-rtl8821aefw
sudo kldload if_rtwn_pci

# Automated install (copies files to /usr/src, builds, installs, loads)
sudo sh install.sh [/usr/src]
```

## Architecture

This driver extends FreeBSD's existing `rtwn(4)` driver framework to support RTL8821AE/RTL8812AE PCIe 802.11ac WiFi NICs. The driver uses a **layered function-pointer architecture**:

1. **PCIe layer** (`rtwn_pci_*`) — Ring buffers, DMA, interrupts
2. **Chip-specific layer** (`r21a_*`, `r12a_*`) — Register access, firmware loading, calibration
3. **Generic layer** (`rtwn_*`) — net80211 integration, rate control, encryption

Key files:
- `sys/dev/rtwn/rtl8821a/pci/` — New driver code (attachment, compat wrappers, TX descriptors)
- `sys/dev/rtwn/pci/rtwn_pci_attach.h` — Modified to add RTL8821AE/8812AE device IDs
- `sys/modules/rtwn_pci/Makefile` — Modified to include new source paths
- `sys/contrib/dev/rtwn/rtwn-rtl8821aefw.fw.uu` — Uuencoded firmware

The private softc is `struct r12a_softc` (shared with RTL8812A), allocated at `sc->sc_priv`. This is **not** `struct r92c_softc` — using the wrong struct type is a recurring source of kernel panics.

## Conventions

- **Naming prefixes**: `r21a_` (RTL8821A), `r12a_` (RTL8812A), `r88e_` (RTL8188E), `r92c_` (RTL8192C). Always use the correct prefix for the chip family.
- **TX descriptors**: RTL8821AE uses 40-byte software TX descriptors (10 DWORDs), not 28 bytes like RTL8192CE. Use `struct r21ae_tx_desc`.
- **Interrupt registers**: RTL8821AE uses `R88E_HIMR` (0x0B0), not `R92C_HIMR` (0x120). Wrong offsets cause interrupt storms and system hangs.
- **Compatibility wrappers**: USB-originated functions that cast to wrong struct types need wrappers in `r21a_pci_compat.c`. Check struct layout before reusing any `r92c_*` function.
- **Descriptor structs**: Use `__packed` with explicit DWORD layout comments and 64-byte alignment.
- **License**: BSD 2-Clause (primary), ISC (some files).
- **C style**: Follow FreeBSD `style(9)`. Headers use `<sys/...>`, `<dev/...>`, `<net80211/...>`.
