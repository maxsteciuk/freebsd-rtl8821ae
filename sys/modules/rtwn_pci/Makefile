.PATH: ${SRCTOP}/sys/dev/rtwn/pci

SYSDIR?=${SRCTOP}/sys
.include "${SYSDIR}/conf/kern.opts.mk"

KMOD     = if_rtwn_pci
SRCS = rtwn_pci_attach.c rtwn_pci_reg.c rtwn_pci_rx.c rtwn_pci_tx.c \
	rtwn_pci_attach.h rtwn_pci_reg.h rtwn_pci_rx.h rtwn_pci_tx.h \
	rtwn_pci_var.h \
	device_if.h bus_if.h pci_if.h \
	opt_bus.h opt_rtwn.h opt_wlan.h

.PATH: ${SRCTOP}/sys/dev/rtwn/rtl8192c/pci
SRCS+= r92ce_attach.c r92ce_calib.c r92ce_fw.c r92ce_init.c r92ce_led.c \
	r92ce_rx.c r92ce_tx.c \
	r92ce.h r92ce_priv.h r92ce_reg.h r92ce_rx_desc.h r92ce_tx_desc.h

.PATH: ${SRCTOP}/sys/dev/rtwn/rtl8188e
SRCS+= r88e_fw.c r88e_calib.c r88e.h

.PATH: ${SRCTOP}/sys/dev/rtwn/rtl8188e/pci
SRCS+= r88ee_attach.c r88ee_init.c r88ee_rx.c \
	r88ee.h r88ee_reg.h

.PATH: ${SRCTOP}/sys/dev/rtwn/rtl8812a
SRCS+= r12a_beacon.c r12a_calib.c r12a_chan.c r12a_fw.c r12a_init.c r12a_led.c r12a_rf.c r12a_rom.c \
	r12a.h r12a_priv.h r12a_reg.h r12a_rom_defs.h r12a_rom_image.h \
	r12a_tx_desc.h r12a_rx_desc.h r12a_fw_cmd.h r12a_var.h

.PATH: ${SRCTOP}/sys/dev/rtwn/rtl8821a
SRCS+= r21a_calib.c r21a_chan.c r21a_init.c r21a_led.c r21a_rom.c \
	r21a.h r21a_priv.h r21a_reg.h

.PATH: ${SRCTOP}/sys/dev/rtwn/rtl8821a/pci
SRCS+= r21a_pci_attach.c r21a_pci_compat.c \
	r21a_pci_attach.h r21ae_tx_desc.h

.PATH: ${SRCTOP}/sys/dev/rtwn/rtl8192c
SRCS+= r92c_calib.c r92c_chan.c r92c_init.c r92c_priv.h r92c_reg.h r92c_var.h

opt_rtwn.h:
	@echo "#define RTWN_DEBUG 1" > ${.TARGET}
.if ${MK_SOURCELESS_UCODE} == "no"
	@echo "#define RTWN_WITHOUT_UCODE 1" >> ${.TARGET}
.endif

.include <bsd.kmod.mk>
