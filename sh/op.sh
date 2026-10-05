#!/bin/bash

function git_sparse_clone() {
  branch="$1" repourl="$2" && shift 2
  git clone --depth=1 -b \(branch --single-branch --filter=blob:none --sparse\)repourl
  repodir=\((echo\)repourl \vert{} awk -F '/' '{print$(NF)}')
  cd \(repodir && git sparse-checkout set\)@
  mv -f $@ ../
  cd .. && rm -rf $repodir
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

# Use QiuSimons' newer daed/luci-app-daed packages while keeping package names
# compatible with the existing luci-app-daed selection.
rm -rf package/porxy/daed package/porxy/luci-app-daed
rm -rf qiu-luci-app-daed
git clone --depth=1 -b kix --single-branch --filter=blob:none --sparse https://github.com/QiuSimons/luci-app-daed qiu-luci-app-daed
pushd qiu-luci-app-daed || exit 1
git sparse-checkout set daed luci-app-daed
popd
mv -f qiu-luci-app-daed/daed qiu-luci-app-daed/luci-app-daed package/porxy/
rm -rf qiu-luci-app-daed

# Match daeuniverse/daed's declared package manager. Floating to latest pnpm
# can change lifecycle-script handling and make the frontend build flaky.
sed -i 's/npm install -g pnpm/npm install -g pnpm@10.24.0/' package/porxy/daed/Makefile
grep -Fq 'npm install -g pnpm@10.24.0' package/porxy/daed/Makefile || {
  echo "ERROR: failed to pin daed pnpm version"
  exit 1
}

# QiuSimons' current daed package builds the upstream monorepo with
# `pnpm build --filter daed`, which can leave apps/web/dist empty or leave
# workspace packages as browser-side bare imports. dae-wing embeds
# webrender/web at Go compile time, so install the pnpm workspace deps, build
# the shared web packages first, build apps/web explicitly, and fail early with
# diagnostics if assets are still missing or cannot run standalone in a browser.
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

missing = []
if not patched_install:
    missing.append("pnpm install")
if not patched_build:
    missing.append("pnpm build --filter daed")
if not patched_copy:
    missing.append("daed web asset copy")
if missing:
    raise SystemExit("ERROR: failed to patch daed Makefile sections: " + ", ".join(missing))

path.write_text("".join(out))
PY
grep -Fq 'pnpm -C apps/web build' package/porxy/daed/Makefile || {
  echo "ERROR: failed to patch daed web build command"
  exit 1
}
grep -Fq 'pnpm --filter @daeuniverse/dae-lsp build' package/porxy/daed/Makefile || {
  echo "ERROR: failed to patch daed workspace package build command"
  exit 1
}
grep -Fq '@daeuniverse/dae-lsp/server/browser' package/porxy/daed/Makefile || {
  echo "ERROR: failed to patch daed vite aliases"
  exit 1
}
grep -Fq 'browser-side bare module imports' package/porxy/daed/Makefile || {
  echo "ERROR: failed to patch daed browser asset validation"
  exit 1
}

# daed listens on plain HTTP by default. If LuCI is opened over HTTPS, the
# upstream iframe helper inherits the HTTPS scheme and points the browser at
# https://router:2023, which fails because daed is not serving TLS.
if [ -f package/porxy/luci-app-daed/luasrc/view/daed/daed.htm ]; then
  sed -i "s/var protocol = window.location.protocol;/var protocol = 'http:';/" \
    package/porxy/luci-app-daed/luasrc/view/daed/daed.htm
fi

# Keep the original daed dashboard assets embedded in dae-wing. QiuSimons'
# Makefile gzips larger JS/CSS assets and may remove the original files; on
# some builds the embedded dashboard then opens as a blank white page because
# the internal HTTP server/browser path does not serve those compressed assets
# correctly.
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
    raise SystemExit("ERROR: failed to find daed dashboard asset gzip/delete rule")

path.write_text("".join(out))
PY
if grep -Fq 'webrender/web -type f -size +4k' package/porxy/daed/Makefile; then
  echo "ERROR: failed to remove daed dashboard asset gzip/delete rule"
  exit 1
fi

rm -rf feeds/luci/applications/{luci-app-dockerman,luci-app-samba4,luci-app-aria2,luci-app-diskman,luci-app-mosdns}
rm -rf feeds/packages/net/{samba4,v2ray-geodata,mosdns,sing-box,aria2,ariang,lucky,adguardhome}

# drop attendedsysupgrade
sed -i '/luci-app-attendedsysupgrade/d' \
    feeds/luci/collections/luci-nginx/Makefile \
    feeds/luci/collections/luci-ssl-openssl/
