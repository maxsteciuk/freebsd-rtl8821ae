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

#ifndef R21AE_TX_DESC_H
#define R21AE_TX_DESC_H

#include <dev/rtwn/rtl8812a/r12a_tx_desc.h>

/*
 * TX MAC descriptor for RTL8821AE/RTL8812AE PCIe.
 *
 * The RTL8821A/8812A family uses 10 DWORDs (40 bytes) of software TX
 * descriptor fields, followed by PCI-specific fields for DMA.
 *
 * Per the Linux reference driver (rtl8821ae/trx.h):
 *   DWORD 7  (offset 28): txbufsize in bits [15:0] — software field
 *   DWORD 8  (offset 32): hwseq_en — software field (NOT txbufaddr!)
 *   DWORD 9  (offset 36): seq — software field
 *   DWORD 10 (offset 40): txbufaddr — PCI DMA address
 *   DWORD 12 (offset 48): nextdescaddr — PCI ring pointer
 *   TX_DESC_NEXT_DESC_OFFSET = 40 (clear first 40 bytes per packet)
 *
 * This differs from RTL8192CE (r92ce_tx_desc) which has only 7 software
 * DWORDs, with txbufaddr at offset 32 and nextdescaddr at offset 40.
 */
struct r21ae_tx_desc {
	/* Software TX descriptor: 40 bytes (DWORDs 0-9) */
	uint16_t	pktlen;
	uint8_t		offset;
	uint8_t		flags0;

	uint32_t	txdw1;
	uint32_t	txdw2;
	uint32_t	txdw3;		/* 32-bit (not 16+16 like r92ce) */
	uint32_t	txdw4;
	uint32_t	txdw5;
	uint32_t	txdw6;

	uint16_t	txbufsize;	/* DWORD 7 bits [15:0] */
	uint16_t	txdw7_hi;	/* DWORD 7 bits [31:16] */

	uint32_t	txdw8;		/* HWSEQ_EN at bit 15 */
	uint32_t	txdw9;		/* SEQ at bits [23:12] */

	/* PCI-specific fields: 24 bytes (DWORDs 10-15) */
	uint32_t	txbufaddr;	/* DWORD 10, offset 40 */
	uint32_t	txbufaddr64;	/* DWORD 11, offset 44 */

	uint32_t	nextdescaddr;	/* DWORD 12, offset 48 */
	uint32_t	nextdescaddr64;	/* DWORD 13, offset 52 */

	uint32_t	reserved[2];	/* DWORDs 14-15 */
} __packed __attribute__((aligned(4)));

#endif	/* R21AE_TX_DESC_H */
