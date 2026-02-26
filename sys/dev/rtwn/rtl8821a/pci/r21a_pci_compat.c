/*-
 * Compatibility wrappers for RTL8821A PCI driver
 * These functions are used by the PCI attachment but are defined in USB code
 */

#include <sys/cdefs.h>
#include "opt_wlan.h"

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/socket.h>
#include <sys/malloc.h>
#include <sys/bus.h>
#include <sys/endian.h>

#include <machine/bus.h>
#include <machine/resource.h>
#include <sys/rman.h>

#include <net/if.h>
#include <net/ethernet.h>
#include <net/if_media.h>
#include <net/route.h>
#include <net/if_var.h>
#include <net80211/ieee80211_var.h>

#include <dev/rtwn/if_rtwnreg.h>
#include <dev/rtwn/if_rtwnvar.h>
#include <dev/rtwn/if_rtwn_debug.h>

#include <dev/rtwn/pci/rtwn_pci_var.h>

#include <dev/rtwn/rtl8192c/r92c_rx_desc.h>
#include <dev/rtwn/rtl8812a/r12a_var.h>
#include <dev/rtwn/rtl8812a/r12a_fw_cmd.h>
#include <dev/rtwn/rtl8812a/r12a_rx_desc.h>
#include <dev/rtwn/rtl8821a/r21a_priv.h>
#include <dev/rtwn/rtl8821a/pci/r21a_pci_attach.h>
#include <dev/rtwn/rtl8821a/pci/r21ae_tx_desc.h>

/* These implementations come from r12au_attach.c */

void
r12a_vap_preattach(struct rtwn_softc *sc, struct ieee80211vap *vap)
{
	struct r12a_softc *rs = sc->sc_priv;
	if_t ifp = vap->iv_ifp;

	if_setcapabilities(ifp, IFCAP_RXCSUM | IFCAP_RXCSUM_IPV6);
	RTWN_LOCK(sc);
	if (rs->rs_flags & R12A_RXCKSUM_EN)
		if_setcapenablebit(ifp, IFCAP_RXCSUM, 0);
	if (rs->rs_flags & R12A_RXCKSUM6_EN)
		if_setcapenablebit(ifp, IFCAP_RXCSUM_IPV6, 0);
	RTWN_UNLOCK(sc);
}

void
r12a_detach_private(struct rtwn_softc *sc)
{
	struct r12a_softc *rs = sc->sc_priv;

	free(rs, M_RTWN_PRIV);
}

/*
 * TX descriptor functions for RTL8821AE/RTL8812AE PCIe.
 *
 * Per the Linux reference driver (rtl8821ae/trx.h), the hardware layout is:
 *   DWORD 7  (offset 28): txbufsize [15:0] — software field
 *   DWORD 8  (offset 32): hwseq_en — software field
 *   DWORD 9  (offset 36): seq — software field
 *   DWORD 10 (offset 40): txbufaddr — PCI DMA bus address
 *   DWORD 12 (offset 48): nextdescaddr — PCI ring pointer
 *   TX_DESC_NEXT_DESC_OFFSET = 40 (software descriptor size)
 *
 * The r92ce functions put txbufaddr at offset 32 and nextdescaddr at
 * offset 40, which is correct for RTL8192CE (7 software DWORDs) but
 * wrong for RTL8821AE (10 software DWORDs).
 */

void
r21ae_setup_tx_desc(struct rtwn_pci_softc *pc, void *desc,
    uint32_t next_desc_addr)
{
	struct r21ae_tx_desc *txd = desc;

	/* DWORD 12 at offset 48. */
	txd->nextdescaddr = htole32(next_desc_addr);
}

void
r21ae_tx_postsetup(struct rtwn_pci_softc *pc, void *desc,
    bus_dma_segment_t segs[])
{
	struct r21ae_tx_desc *txd = desc;

	/* DWORD 10 at offset 40. */
	txd->txbufaddr = htole32(segs[0].ds_addr);
	/* DWORD 7 lower 16 bits at offset 28. */
	txd->txbufsize = txd->pktlen;
	bus_space_barrier(pc->pc_st, pc->pc_sh, 0, pc->pc_mapsize,
	    BUS_SPACE_BARRIER_WRITE);
}

void
r21ae_copy_tx_desc(void *dest, const void *src)
{
	/*
	 * Copy all 40 bytes of the software TX descriptor (DWORDs 0-9).
	 * This preserves PCI fields at offset 40+ (txbufaddr, nextdescaddr)
	 * which are set by setup_tx_desc and tx_postsetup.
	 * Matches Linux TX_DESC_NEXT_DESC_OFFSET = 40.
	 */
	const size_t len = 40;

	if (src != NULL)
		memcpy(dest, src, len);
	else
		memset(dest, 0, len);
}

void
r21ae_dump_tx_desc(struct rtwn_softc *sc, const void *desc)
{
#ifdef RTWN_DEBUG
	const struct r21ae_tx_desc *txd = desc;

	RTWN_DPRINTF(sc, RTWN_DEBUG_XMIT_DESC,
	    "%s: len %d, off %d, flags0 %02X, dw: 1 %08X, 2 %08X, 3 %08X, "
	    "4 %08X, 5 %08X, 6 %08X, 7 %04X%04X, 8 %08X, 9 %08X, "
	    "size %04X, addr: %08X (64: %08X), next: %08X (64: %08X)\n",
	    __func__, le16toh(txd->pktlen), txd->offset, txd->flags0,
	    le32toh(txd->txdw1), le32toh(txd->txdw2), le32toh(txd->txdw3),
	    le32toh(txd->txdw4), le32toh(txd->txdw5), le32toh(txd->txdw6),
	    le16toh(txd->txdw7_hi), le16toh(txd->txbufsize),
	    le32toh(txd->txdw8), le32toh(txd->txdw9),
	    le16toh(txd->txbufsize),
	    le32toh(txd->txbufaddr), le32toh(txd->txbufaddr64),
	    le32toh(txd->nextdescaddr), le32toh(txd->nextdescaddr64));
#endif
}

/*
 * Interrupt classification for RTL8812A/RTL8821A on PCIe.
 *
 * r92c_classify_intr() always returns RTWN_RX_DATA because the RTL8192C
 * fetches C2H reports from a register, not the RX path.  The r12a family
 * delivers C2H reports (including TX status) through the RX ring and
 * marks them with R12A_RXDW2_RPT_C2H.  Without proper classification,
 * firmware events are misinterpreted as WiFi frames.
 */
int
r21ae_classify_intr(struct rtwn_softc *sc, void *buf, int len)
{
	struct r92c_rx_stat *stat = buf;
	uint32_t rxdw2 = le32toh(stat->rxdw2);

	if (rxdw2 & R12A_RXDW2_RPT_C2H) {
		int pos = sizeof(struct r92c_rx_stat);
		if (len < pos + 2)
			return (RTWN_RX_DATA);

		if (((uint8_t *)buf)[pos] == R12A_C2H_TX_REPORT)
			return (RTWN_RX_TX_REPORT);
		else
			return (RTWN_RX_OTHER);
	} else
		return (RTWN_RX_DATA);
}
