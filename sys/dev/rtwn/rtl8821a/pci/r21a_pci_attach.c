/*-
 * Copyright (c) 2016 Andriy Voskoboinyk <avos@FreeBSD.org>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <sys/cdefs.h>
#include "opt_wlan.h"

#include <sys/param.h>
#include <sys/lock.h>
#include <sys/mutex.h>
#include <sys/mbuf.h>
#include <sys/kernel.h>
#include <sys/socket.h>
#include <sys/systm.h>
#include <sys/malloc.h>
#include <sys/queue.h>
#include <sys/taskqueue.h>
#include <sys/bus.h>
#include <sys/endian.h>
#include <sys/linker.h>
#include <sys/rman.h>

#include <machine/bus.h>
#include <machine/resource.h>

#include <net/if.h>
#include <net/ethernet.h>
#include <net/if_media.h>

#include <net80211/ieee80211_var.h>
#include <net80211/ieee80211_radiotap.h>

#include <dev/rtwn/if_rtwnreg.h>
#include <dev/rtwn/if_rtwnvar.h>
#include <dev/rtwn/if_rtwn_nop.h>

#include <dev/rtwn/pci/rtwn_pci_var.h>

#include <dev/rtwn/rtl8192c/r92c_var.h>
#include <dev/rtwn/rtl8192c/pci/r92ce.h>
#include <dev/rtwn/rtl8192c/pci/r92ce_reg.h>
#include <dev/rtwn/rtl8192c/r92c_reg.h>

#include <dev/rtwn/rtl8812a/r12a_var.h>
#include <dev/rtwn/rtl8812a/r12a.h>
#include <dev/rtwn/rtl8812a/r12a_reg.h>

#include <dev/rtwn/rtl8188e/r88e.h>
#include <dev/rtwn/rtl8188e/pci/r88ee.h>

#include <dev/rtwn/rtl8821a/r21a.h>
#include <dev/rtwn/rtl8821a/r21a_priv.h>
#include <dev/rtwn/rtl8821a/r21a_reg.h>
#include <dev/rtwn/rtl8821a/pci/r21a_pci_attach.h>
#include <dev/rtwn/rtl8821a/pci/r21ae_tx_desc.h>

void	r21a_pci_attach(struct rtwn_pci_softc *);

/*
 * r92c_scan_start/end cast sc->sc_priv to struct r92c_softc, but
 * the RTL8821AE uses struct r12a_softc where rs_scan_start/end
 * live at different offsets (0x190 vs 0x70).  Using the r92c
 * versions reads NULL from the wrong offset and panics the kernel.
 */
static void
r21a_pci_scan_start(struct ieee80211com *ic)
{
	struct rtwn_softc *sc = ic->ic_softc;
	struct r12a_softc *rs = sc->sc_priv;

	rs->rs_scan_start(ic);
}

static void
r21a_pci_scan_end(struct ieee80211com *ic)
{
	struct rtwn_softc *sc = ic->ic_softc;
	struct r12a_softc *rs = sc->sc_priv;

	rs->rs_scan_end(ic);
}

static void
r21a_pci_postattach(struct rtwn_softc *sc)
{
	struct r12a_softc *rs = sc->sc_priv;
	struct ieee80211com *ic = &sc->sc_ic;

	/* DFS */
	rs->rs_scan_start = ic->ic_scan_start;
	ic->ic_scan_start = r21a_pci_scan_start;
	rs->rs_scan_end = ic->ic_scan_end;
	ic->ic_scan_end = r21a_pci_scan_end;
}

static void
r21a_pci_post_init(struct rtwn_softc *sc)
{

	rtwn_write_2(sc, R92C_FWHW_TXQ_CTRL,
	    0x1f00 | R92C_FWHW_TXQ_CTRL_AMPDU_RTY_NEW);
	rtwn_write_1(sc, R92C_BCN_MAX_ERR, 0xff);

	/* Perform IQ and LC calibrations. */
	rtwn_iq_calib(sc);
	rtwn_lc_calib(sc);

	/* Enable Rx DMA. */
	rtwn_write_1(sc, R92C_PCIE_CTRL_REG + 1, 0);

#ifndef RTWN_WITHOUT_UCODE
	if (sc->sc_flags & RTWN_FW_LOADED) {
		if (sc->sc_ratectl_sysctl == RTWN_RATECTL_FW) {
			/* No support (yet?) for f/w rate adaptation. */
			sc->sc_ratectl = RTWN_RATECTL_NET80211;
		} else
			sc->sc_ratectl = sc->sc_ratectl_sysctl;
	} else
#endif
		sc->sc_ratectl = RTWN_RATECTL_NONE;
}

static void
r21a_pci_attach_private(struct rtwn_softc *sc)
{
	struct r12a_softc *rs;

	rs = malloc(sizeof(struct r12a_softc), M_RTWN_PRIV, M_WAITOK | M_ZERO);

	rs->rs_fix_spur			= rtwn_nop_softc_chan;
	rs->rs_set_band_2ghz		= r21a_set_band_2ghz;
	rs->rs_set_band_5ghz		= r21a_set_band_5ghz;
	rs->rs_init_ampdu_fwhw		= r21a_init_ampdu_fwhw;
	rs->rs_crystalcap_write		= r21a_crystalcap_write;
#ifndef RTWN_WITHOUT_UCODE
	rs->rs_iq_calib_fw_supported	= r21a_iq_calib_fw_supported;
#endif
	rs->rs_iq_calib_sw		= r21a_iq_calib_sw;

	rs->rs_flags			= R12A_RXCKSUM_EN | R12A_RXCKSUM6_EN;

	rs->ampdu_max_time		= 0x5e;
	rs->ampdu_max_size		= 0xffff;

	sc->sc_priv			= rs;
}

static void
r21a_pci_adj_devcaps(struct rtwn_softc *sc)
{
	struct ieee80211com *ic = &sc->sc_ic;

	ic->ic_htcaps |= IEEE80211_HTC_TXLDPC;

	ic->ic_htcaps |=
	    IEEE80211_HTCAP_CHWIDTH40 |
	    IEEE80211_HTCAP_SHORTGI40;

	/* VHT config */
	ic->ic_flags_ext |= IEEE80211_FEXT_VHT;
	ic->ic_vht_cap.vht_cap_info =
	    IEEE80211_VHTCAP_MAX_MPDU_LENGTH_11454 |
	    IEEE80211_VHTCAP_SHORT_GI_80 |
	    IEEE80211_VHTCAP_TXSTBC |
	    IEEE80211_VHTCAP_RXSTBC_1 |
	    IEEE80211_VHTCAP_HTC_VHT |
	    _IEEE80211_SHIFTMASK(7,
	        IEEE80211_VHTCAP_MAX_A_MPDU_LENGTH_EXPONENT_MASK);

	rtwn_attach_vht_cap_info_mcs(sc);
}

void
r21a_pci_attach(struct rtwn_pci_softc *pc)
{
	struct rtwn_softc *sc		= &pc->pc_sc;

	/* PCIe part. */
	pc->pc_setup_tx_desc		= r21ae_setup_tx_desc;
	pc->pc_tx_postsetup		= r21ae_tx_postsetup;
	pc->pc_copy_tx_desc		= r21ae_copy_tx_desc;
	/*
	 * RTL8821AE uses interrupt registers at 0x0B0-0x0BC (R88E_HIMR/HISR),
	 * not 0x120-0x12C (R92C_HIMR/HISR).  Using the wrong offsets causes
	 * an interrupt storm on ifconfig up — the handler never acknowledges
	 * the real interrupt, so the hardware refires it in a tight loop,
	 * hanging the system.  Use the r88ee functions which target 0x0B0.
	 */
	pc->pc_enable_intr		= r88ee_enable_intr;
	pc->pc_get_intr_status		= r88ee_get_intr_status;

	pc->pc_qmap			= 0xe771;
	pc->tcr				= 0x8200;

	/* Common part. */
	sc->sc_flags			= RTWN_FLAG_EXT_HDR;

	sc->sc_set_chan			= r12a_set_chan;
	sc->sc_fill_tx_desc		= r12a_fill_tx_desc;
	sc->sc_fill_tx_desc_raw		= r12a_fill_tx_desc_raw;
	sc->sc_fill_tx_desc_null	= r12a_fill_tx_desc_null;
	sc->sc_dump_tx_desc		= r21ae_dump_tx_desc;
	sc->sc_tx_radiotap_flags	= r12a_tx_radiotap_flags;
	sc->sc_rx_radiotap_flags	= r12a_rx_radiotap_flags;
	sc->sc_get_rx_stats		= r12a_get_rx_stats;
	sc->sc_get_rssi_cck		= r21a_get_rssi_cck;
	sc->sc_get_rssi_ofdm		= r88e_get_rssi_ofdm;
	sc->sc_classify_intr		= r21ae_classify_intr;
	sc->sc_handle_tx_report		= r12a_ratectl_tx_complete;
	sc->sc_handle_tx_report2	= rtwn_nop_softc_uint8_int;
	sc->sc_handle_c2h_report	= r12a_handle_c2h_report;
	sc->sc_check_frame		= r12a_check_frame_checksum;
	sc->sc_rf_read			= r12a_c_cut_rf_read;
	sc->sc_rf_write			= r12a_rf_write;
	sc->sc_check_condition		= r21a_check_condition;
	sc->sc_efuse_postread		= rtwn_nop_softc;
	sc->sc_parse_rom		= r21a_parse_rom;
	sc->sc_set_led			= r21a_set_led;
	sc->sc_power_on			= r21a_power_on;
	sc->sc_power_off		= r21a_power_off;
#ifndef RTWN_WITHOUT_UCODE
	sc->sc_fw_reset			= r21a_fw_reset;
	sc->sc_fw_download_enable	= r12a_fw_download_enable;
#endif
	sc->sc_llt_init			= r92c_llt_init;
	sc->sc_set_page_size		= r92c_set_page_size;
	sc->sc_lc_calib			= rtwn_nop_softc;
	sc->sc_iq_calib			= r12a_iq_calib;
	sc->sc_read_chipid_vendor	= rtwn_nop_softc_uint32;
	sc->sc_adj_devcaps		= r21a_pci_adj_devcaps;
	sc->sc_vap_preattach		= r12a_vap_preattach;
	sc->sc_postattach		= r21a_pci_postattach;
	sc->sc_detach_private		= r12a_detach_private;
	sc->sc_set_media_status		= r12a_set_media_status;
#ifndef RTWN_WITHOUT_UCODE
	sc->sc_set_rsvd_page		= r88e_set_rsvd_page;
	sc->sc_set_pwrmode		= r12a_set_pwrmode;
	sc->sc_set_rssi			= rtwn_nop_softc;
#endif
	sc->sc_beacon_init		= r21a_beacon_init;
	sc->sc_beacon_enable		= r92c_beacon_enable;
	sc->sc_sta_beacon_enable	= r12a_sta_beacon_enable;
	sc->sc_beacon_set_rate		= r12a_beacon_set_rate;
	sc->sc_beacon_select		= r21a_beacon_select;
	sc->sc_temp_measure		= r88e_temp_measure;
	sc->sc_temp_read		= r88e_temp_read;
	sc->sc_init_tx_agg		= rtwn_nop_softc;
	sc->sc_init_rx_agg		= rtwn_nop_softc;
	sc->sc_init_ampdu		= r92ce_init_ampdu;
	sc->sc_init_intr		= r88ee_init_intr;	/* 0x0B0, not 0x120 */
	sc->sc_start_xfers		= r88ee_start_xfers;	/* 0x0B0, not 0x120 */
	sc->sc_init_edca		= r92ce_init_edca;
	sc->sc_init_bb			= r12a_init_bb;
	sc->sc_init_rf			= r12a_init_rf;
	sc->sc_init_antsel		= r12a_init_antsel;
	sc->sc_post_init		= r21a_pci_post_init;
	sc->sc_init_bcnq1_boundary	= r21a_init_bcnq1_boundary;
	sc->sc_set_tx_power		= rtwn_nop_int_softc_vap;

	sc->chan_list_5ghz[0]		= r12a_chan_5ghz_0;
	sc->chan_list_5ghz[1]		= r12a_chan_5ghz_1;
	sc->chan_list_5ghz[2]		= r12a_chan_5ghz_2;
	sc->chan_num_5ghz[0]		= nitems(r12a_chan_5ghz_0);
	sc->chan_num_5ghz[1]		= nitems(r12a_chan_5ghz_1);
	sc->chan_num_5ghz[2]		= nitems(r12a_chan_5ghz_2);

	sc->mac_prog			= &rtl8821au_mac[0];
	sc->mac_size			= nitems(rtl8821au_mac);
	sc->bb_prog			= &rtl8821au_bb[0];
	sc->bb_size			= nitems(rtl8821au_bb);
	sc->agc_prog			= &rtl8821au_agc[0];
	sc->agc_size			= nitems(rtl8821au_agc);
	sc->rf_prog			= &rtl8821au_rf[0];

	sc->name			= "RTL8821AE";
	sc->fwname			= "rtwn-rtl8821aefw";
	sc->fwsig			= 0x210;

	sc->page_count			= R21A_TX_PAGE_COUNT;
	sc->pktbuf_count		= R12A_TXPKTBUF_COUNT;

	sc->ackto			= 0x80;
	sc->npubqpages			= R12A_PUBQ_NPAGES;
	sc->page_size			= R21A_TX_PAGE_SIZE;

	sc->txdesc_len			= sizeof(struct r21ae_tx_desc);
	sc->efuse_maxlen		= R12A_EFUSE_MAX_LEN;
	sc->efuse_maplen		= R12A_EFUSE_MAP_LEN;
	sc->rx_dma_size			= R12A_RX_DMA_BUFFER_SIZE;

	sc->macid_limit			= R12A_MACID_MAX + 1;
	sc->cam_entry_limit		= R12A_CAM_ENTRY_COUNT;
	sc->fwsize_limit		= R12A_MAX_FW_SIZE;
	sc->temp_delta			= R88E_CALIB_THRESHOLD;

	sc->bcn_status_reg[0]		= R92C_TDECTRL;
	sc->bcn_status_reg[1]		= R92C_TDECTRL;
	sc->rcr				= R12A_RCR_DIS_CHK_14 |
					  R12A_RCR_VHT_ACK |
					  R12A_RCR_TCP_OFFLD_EN;

	sc->ntxchains			= 1;
	sc->nrxchains			= 1;

	sc->sc_ht40			= 1;

	r21a_pci_attach_private(sc);
}

