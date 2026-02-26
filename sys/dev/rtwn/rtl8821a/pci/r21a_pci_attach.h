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

#ifndef R21A_PCI_ATTACH_H
#define R21A_PCI_ATTACH_H

struct rtwn_softc;
struct rtwn_pci_softc;
struct ieee80211vap;

void	r12a_vap_preattach(struct rtwn_softc *, struct ieee80211vap *);
void	r12a_detach_private(struct rtwn_softc *);
void	r12a_set_media_status(struct rtwn_softc *, int);
int	r88e_set_rsvd_page(struct rtwn_softc *, int, int, int);
void	r12a_sta_beacon_enable(struct rtwn_softc *, int, bool);
void	r12a_beacon_set_rate(void *, int);
void	r88e_temp_measure(struct rtwn_softc *);
uint8_t	r88e_temp_read(struct rtwn_softc *);

/* RTL8821AE/RTL8812AE PCI TX descriptor functions. */
void	r21ae_setup_tx_desc(struct rtwn_pci_softc *, void *, uint32_t);
void	r21ae_tx_postsetup(struct rtwn_pci_softc *, void *,
	    bus_dma_segment_t[]);
void	r21ae_copy_tx_desc(void *, const void *);
void	r21ae_dump_tx_desc(struct rtwn_softc *, const void *);

/* RTL8812A/RTL8821A PCI interrupt classification. */
int	r21ae_classify_intr(struct rtwn_softc *, void *, int);

#endif	/* R21A_PCI_ATTACH_H */
