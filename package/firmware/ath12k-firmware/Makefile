
include $(TOPDIR)/rules.mk

PKG_NAME:=ath12k-firmware
PKG_SOURCE_DATE:=2026-10-18
PKG_SOURCE_VERSION:=ae13c14c9dfbf48cbf84c67a940869581a0f4c71
PKG_MIRROR_HASH:=abc31a905a7f9d08626b33ae2c34461cd2f98b19f28482fe61d702358772c7b0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/VIKINGYFY/ath12k-firmware-ddwrt.git

PKG_LICENSE_FILES:=QCN9274/hw1.0/Notice.txt

PKG_MAINTAINER:=VIKING <viking.yfy@qq.com>

include $(INCLUDE_DIR)/package.mk

RSTRIP:=:
STRIP:=:

define Package/ath12k-firmware-default
  SECTION:=firmware
  CATEGORY:=Firmware
  URL:=$(PKG_SOURCE_URL)
  DEPENDS:=
endef

define Package/ath12k-firmware-ipq5332-ddwrt
$(Package/ath12k-firmware-default)
  TITLE:=IPQ5332 ath12k firmware DD-WRT
endef

define Package/ath12k-firmware-qcn9274-ddwrt
$(Package/ath12k-firmware-default)
  TITLE:=QCN9274 ath12k firmware (DD-WRT and Qualcomm)
endef

define Build/Compile

endef

define Package/ath12k-firmware-ipq5332-ddwrt/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath12k/IPQ5332/hw1.0/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/IPQ5332/hw1.0/* $(1)/lib/firmware/ath12k/IPQ5332/hw1.0/
endef

define Package/ath12k-firmware-qcn9274-ddwrt/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath12k/QCN9274/hw1.0/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/QCN9274/hw1.0/* $(1)/lib/firmware/ath12k/QCN9274/hw1.0/
	$(INSTALL_DIR) $(1)/lib/firmware/ath12k/QCN9274/hw2.0/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/QCN9274/hw2.0/* $(1)/lib/firmware/ath12k/QCN9274/hw2.0/
endef

$(eval $(call BuildPackage,ath12k-firmware-ipq5332-ddwrt))
$(eval $(call BuildPackage,ath12k-firmware-qcn9274-ddwrt))
