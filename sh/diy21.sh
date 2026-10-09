#!/bin/bash
#
# DIY_P2: Inject Aigo AGS21 device support
#

PATCH_DIR="${GITHUB_WORKSPACE}/patch/aigo-ags21"
DTS_SRC="${PATCH_DIR}/mt7981b-aigo-ags21.dts"
DTS_DST="target/linux/mediatek/dts/mt7981b-aigo-ags21.dts"

FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
NETWORK_SH="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
PLATFORM_SH="target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
UBOOT_ENV="package/boot/uboot-tools/uboot-envtools/files/mediatek_filogic"

echo "=========================================="
echo "正在注入 Aigo AGS21 设备支持..."
echo "=========================================="

if [ ! -f "$DTS_SRC" ]; then
    echo "❌ 未找到设备树文件: $DTS_SRC"
    exit 1
fi

echo ">>> 复制设备树到源码目录..."
cp -f "$DTS_SRC" "$DTS_DST"

if ! grep -q 'define Device/aigo_ags21' "$FILOGIC_MK"; then
    echo ">>> 注册 filogic.mk 设备 profile..."
    cat >> "$FILOGIC_MK" << 'EOF'

define Device/aigo_ags21
	DEVICE_VENDOR := Aigo
	DEVICE_MODEL := AGS21
	DEVICE_DTS := mt7981b-aigo-ags21
	DEVICE_DTS_DIR := ../dts
	DEVICE_PACKAGES := f2fsck mkf2fs kmod-mmc mmc-utils automount
	KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
	KERNEL_INITRAMFS := kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
	IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += aigo_ags21
EOF
    echo "✅ filogic.mk 已更新"
fi

if [ -f "$PLATFORM_SH" ] && ! grep -q 'aigo,ags21' "$PLATFORM_SH"; then
    echo ">>> 添加 eMMC sysupgrade 支持 (platform.sh)..."
    sed -i '/umi,uax3000e|\\/a\	aigo,ags21|\\' "$PLATFORM_SH"
    echo "✅ platform.sh 已更新"
fi

if [ -f "$NETWORK_SH" ] && ! grep -q 'aigo,ags21' "$NETWORK_SH"; then
    echo ">>> 添加默认网口布局 (02_network)..."
    sed -i '/^\t\*)/i\
	aigo,ags21)\
		ucidef_set_interfaces_lan_wan "lan1 lan2" eth1\
		;;' "$NETWORK_SH"
    echo "✅ 02_network 已更新"
fi

if [ -f "$UBOOT_ENV" ] && ! grep -q 'aigo,ags21' "$UBOOT_ENV"; then
    echo ">>> 添加 U-Boot env 支持 (uboot-envtools)..."
    sed -i '/acer,vero-w6m|\\/a\	aigo,ags21|\\' "$UBOOT_ENV"
    echo "✅ uboot-envtools 已更新"
fi

echo "✅ Aigo AGS21 设备支持注入完成"
