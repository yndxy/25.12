#!/bin/bash

function git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  shift 2
  git clone --depth=1 -b "\(branch" --single-branch --filter=blob:none --sparse "\)repourl"
  local repodir=\((echo "\)repourl" | awk -F '/' '{print $(NF)}')
  cd "\(repodir" && git sparse-checkout set "\)@"
  mv -f "$@" ../
  cd .. && rm -rf "$repodir"
}

set -x

apply_patch_once() {
    patch_file="$1"

    echo "Applying $patch_file ..."
    if patch -p1 --dry-run --silent < "$patch_file"; then
        patch -p1 --forward --no-backup-if-mismatch < "$patch_file"
    elif patch -R -p1 --dry-run --silent < "$patch_file"; then
        echo "Skipping $patch_file: already applied"
    else
        echo "ERROR: Failed to apply $patch_file"
        return 1
    fi
}

# kenrel Vermagic
sed -ie 's/^\(.\).*vermagic\(/\1cp\)(TOPDIR)\/.vermagic $(LINUX_DIR)\/.vermagic/' include/kernel-defaults.mk
grep HASH target/linux/generic/kernel-6.12 | awk -F'HASH-' '{print $2}' | awk '{print $1}' | md5sum | awk '{print $1}' > .vermagic

git clone -b packages --depth 1 --single-branch https://github.com/shiyu1314/openwrt-feeds package/xd
git clone -b porxy --depth 1 --single-branch https://github.com/shiyu1314/openwrt-feeds package/porxy

[ -f package/xd/smartdns/Makefile ] && sed -i -E \
  -e 's/[[:space:]]*PACKAGE_smartdns-ui:rust-bindgen\/host//g' \
  -e 's/[[:space:]]*rust-bindgen\/host//g' \
  -e 's/[[:space:]]*PACKAGE_smartdns-ui://g' \
  package/xd/smartdns/Makefile

rm -rf package/porxy/daed package/porxy/luci-app-daed
rm -rf qiu-luci-app-daed
git clone --depth=1 -b kix --single-branch --filter=blob:none --sparse https://github.com/QiuSimons/luci-app-daed qiu-luci-app-daed
pushd qiu-luci-app-daed || exit 1
git sparse-checkout set daed luci-app-daed
popd
mv -f qiu-luci-app-daed/daed qiu-luci-app-daed/luci-app-daed package/porxy/
rm -rf qiu-luci-app-daed

sed -i 's/npm install -g pnpm/npm install -g pnpm@10.24.0/' package/porxy/daed/Makefile
grep -Fq 'npm install -g pnpm@10.24.0' package/porxy/daed/Makefile || {
  echo "ERROR: failed to pin daed pnpm version"
  exit 1
}

python3 - <<'PY'
from pathlib import Path

path = Path("package/porxy/daed/Makefile")
lines = path.read_text().splitlines(keepends=True)
out = []
patched_install = False
patched_build = False
patched_copy = False

for line in lines:
    stripped = line.strip()
    if stripped == "pnpm install ; \\":
        out.extend([
            "\t\t\tpnpm install --frozen-lockfile || pnpm install --no-frozen-lockfile ; \\\n",
            "\t\t\tsed -i \"/@daeuniverse\\\\/dae-editor/a\\\\        '@daeuniverse/dae-lang-core': path.resolve(__dirname, '../../packages/dae-lang-core/src/index.ts'),\\\\n        '@daeuniverse/dae-lsp/server/browser': path.resolve(__dirname, '../../packages/dae-lsp/src/browser-server.ts'),\" apps/web/vite.config.ts ; \\\n",
        ])
        patched_install = True
        continue
    if stripped == "pnpm build --filter daed ; \\":
        out.extend([
            "\t\t\tpnpm --filter @daeuniverse/dae-lang-core build ; \\\n",
            "\t\t\tpnpm --filter @daeuniverse/dae-node-parser build ; \\\n",
            "\t\t\tpnpm --filter @daeuniverse/dae-lsp build ; \\\n",
            "\t\t\tpnpm --filter @daeuniverse/dae-editor build ; \\\n",
            "\t\t\tpnpm -C apps/web build ; \\\n",
        ])
        patched_build = True
        continue
    if "cp -rf \((DAED_BUILD_DIR)/apps/web/dist/*\)(PKG_BUILD_DIR)/webrender/web" in line:
        out.extend([
            "\t\tcp -rf \((DAED_BUILD_DIR)/apps/web/dist/.\)(PKG_BUILD_DIR)/webrender/web ; \\\n",
            "\t\ttest -s \((PKG_BUILD_DIR)/webrender/web/index.html || { echo \"ERROR: daed web assets were not generated\"; find\)(DAED_BUILD_DIR)/apps -maxdepth 4 -type f | sort | tail -200; exit 1; } ; \\\n",
            "\t\tfind $(PKG_BUILD_DIR)/webrender/web -type f -print -quit | grep -q . || { echo \"ERROR: dae-wing webrender/web is empty\"; exit 1; } ; \\\n",
            "\t\tif grep -RInE \"^[[:space:]]*import[[:space:]]+(.*from[[:space:]]+)?[\\\"'][^./][^\\\"']*[\\\"']\" $(PKG_BUILD_DIR)/webrender/web/assets/*.js 2>/dev/null ; then echo \"ERROR: daed web assets contain browser-side bare module imports\"; exit 1; fi ; \\\n",
        ])
        patched_copy = True
        continue
    out.append(line)

if not patched_install or not patched_build or not patched_copy:
    raise SystemExit("ERROR: failed to patch daed Makefile sections")

path.write_text("".join(out))
PY

if [ -f package/porxy/luci-app-daed/luasrc/view/daed/daed.htm ]; then
  sed -i "s/var protocol = window.location.protocol;/var protocol = 'http:';/" \
    package/porxy/luci-app-daed/luasrc/view/daed/daed.htm
fi

python3 - <<'PY'
from pathlib import Path
path = Path("package/porxy/daed/Makefile")
lines = path.read_text().splitlines(keepends=True)
out = []
removed = False
i = 0
while i < len(lines):
    line = lines[i]
    if "find $(PKG_BUILD_DIR)/webrender/web -type f -size +4k" in line:
        out.append('\t\techo "Keeping uncompressed daed dashboard assets for embedded web UI" ; \\\n')
        removed = True
        i += 1
        while i < len(lines):
            if lines[i].lstrip().startswith('";" ;'):
                i += 1
                break
            i += 1
        continue
    out.append(line)
    i += 1
if not removed:
    raise SystemExit("ERROR: failed to find daed dashboard asset rule")
path.write_text("".join(out))
PY

rm -rf feeds/luci/applications/{luci-app-dockerman,luci-app-samba4,luci-app-aria2,luci-app-diskman,luci-app-mosdns}
rm -rf feeds/packages/net/{samba4,v2ray-geodata,mosdns,sing-box,aria2,ariang,lucky,adguardhome}

sed -i '/luci-app-attendedsysupgrade/d' \
    feeds/luci/collections/luci-nginx/Makefile \
    feeds/luci/collections/luci-ssl-openssl/Makefile \
    feeds/luci/collections/luci-ssl/Makefile \
    feeds/luci/collections/luci/Makefile
    
sed -i 's/+uhttpd /+luci-nginx /g' feeds/luci/collections/luci/Makefile
sed -i 's/+uhttpd-mod-ubus //' feeds/luci/collections/luci/Makefile
sed -i 's/+uhttpd /+luci-nginx /g' feeds/luci/collections/luci-light/Makefile
sed -i "s/+luci /+luci-nginx /g" feeds/luci/collections/luci-ssl-openssl/Makefile
sed -i "s/+luci /+luci-nginx /g" feeds/luci/collections/luci-ssl/Makefile
sed -i 's/+uhttpd +uhttpd-mod-ubus /+luci-nginx /g' feeds/packages/net/wg-installer/Makefile
sed -i '/uhttpd-mod-ubus/d' feeds/luci/collections/luci-light/Makefile
sed -i 's/+luci-nginx \\$/+luci-nginx/' feeds/luci/collections/luci-light/Makefile

pushd feeds/luci || exit 1
for patch in *.patch; do
    [ -f "$patch" ] || continue
    apply_patch_once "$patch" || { popd; exit 1; }
done
popd

# ==========================================
# Aigo AGS21 eMMC 机型自动注入与注册
# ==========================================
python3 - << 'PY'
import os
from pathlib import Path

workspace = os.environ.get("GITHUB_WORKSPACE", ".")
dts_src = Path(workspace) / "patch/mt7981-aigo-ags21.dts"
dts_dst = Path("target/linux/mediatek/dts/mt7981-aigo-ags21.dts")
if dts_src.exists():
    dts_dst.parent.mkdir(parents=True, exist_ok=True)
    dts_dst.write_bytes(dts_src.read_bytes())
    print("Aigo AGS21 DTS injected successfully.")

filogic_mk = Path("target/linux/mediatek/image/filogic.mk")
if filogic_mk.exists():
    content = filogic_mk.read_text()
    if "Device/aigo_ags21" not in content:
        snippet = """
define Device/aigo_ags21
  DEVICE_VENDOR := Aigo
  DEVICE_MODEL := AGS21
  DEVICE_DTS := mt7981-aigo-ags21
  DEVICE_DTS_DIR := $(DTS_DIR)
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := append-kernel | fit gzip \((KDIR)/image-\)(firstword $(DEVICE_DTS)).dtb | append-metadata
  DEVICE_PACKAGES := kmod-usb-ohci kmod-usb2 kmod-mmc
endef
TARGET_DEVICES += aigo_ags21
"""
        filogic_mk.write_text(content + snippet)
        print("aigo_ags21 registered in filogic.mk successfully.")
PY

# rust
RUST_VERSION=1.95.0
RUST_HASH=62b67230754da642a264ca0cb9fc08820c54e2ed7b3baba0289876d4cdb48c08
sed -ri "s/(PKG_VERSION:=)[^\"]*/\1\(RUST_VERSION/;s/(PKG_HASH:=)[^\"]*/\1\)RUST_HASH/" feeds/packages/lang/rust/Makefile

# fstools & utils
rm -rf package/system/fstools
git clone https://github.com/sbwml/package_system_fstools -b openwrt-25.12 package/system/fstools
rm -rf package/utils/util-linux
git clone https://github.com/sbwml/package_utils_util-linux -b openwrt-25.12 package/utils/util-linux

# libs & curl
rm -rf feeds/packages/libs/nghttp3
git clone https://github.com/sbwml/package_libs_nghttp3 package/libs/nghttp3
rm -rf feeds/packages/libs/ngtcp2
git clone https://github.com/sbwml/package_libs_ngtcp2 package/libs/ngtcp2
rm -rf feeds/packages/net/curl
git clone https://github.com/sbwml/feeds_packages_net_curl feeds/packages/net/curl

# nginx
rm -rf feeds/packages/net/nginx
git clone https://github.com/sbwml/feeds_packages_net_nginx feeds/packages/net/nginx -b openwrt-25.12
sed -i 's/procd_set_param stdout 1/procd_set_param stdout 0/g;s/procd_set_param stderr 1/procd_set_param stderr 0/g' feeds/packages/net/nginx/files/nginx.init
sed -i 's/ubus_parallel_req 2/ubus_parallel_req 6/g' feeds/packages/net/nginx/files-luci-support/60_nginx-luci-support
sed -i '/ubus_parallel_req/a\        ubus_script_timeout 300;' feeds/packages/net/nginx/files-luci-support/60_nginx-luci-support
sed -i '/\/etc\/nginx\/uci.conf.template/d' feeds/packages/net/nginx-util/Makefile

# uwsgi
sed -i '$a cgi-timeout = 600' feeds/packages/net/uwsgi/files-luci-support/luci-*.ini
sed -i '/limit-as/c\limit-as = 5000' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i "s/procd_set_param stderr 1/procd_set_param stderr 0/g" feeds/packages/net/uwsgi/files/uwsgi.init
sed -i 's/threads = 1/threads = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/processes = 3/processes = 4/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/cheaper = 1/cheaper = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini

# rpcd & luci-compat
sed -i 's/option timeout 30/option timeout 60/g' package/system/rpcd/files/rpcd.config
sed -i 's#20) \* 1000#60) \* 1000#g' feeds/luci/modules/luci-base/htdocs/luci-static/resources/rpc.js
sed -i '/
