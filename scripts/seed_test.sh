#!/bin/bash

# Copyright (c) 2026 Sha0huaZhang <zsh@finx.sh>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110, USA.
#
#
# seed_test.sh - 种子打包器与安装器的往返验证
#
# 被测的是一条会决定所有人下载到什么的路径：scripts/make_seed.sh 打出来的
# 东西交给 finx-install/install.sh 去装。两边任何一边走偏都不会当场报错 ——
# 只会装出一个缺文件、或者配置指向构建机的前缀。所以这里真的跑一遍。
#
# 重点在「该剔的有没有剔，该留的有没有留」，因为那些判断都来自对 dpkg 与
# fink 行为的推断，而不是显而易见的事实：
#
#   src/、var/log/            构建机的产物，不该进用户机器
#   etc/finx.conf             安装器要按实际前缀重写；带进种子会把前缀钉死
#   fink/debs/里面的链接      指向 src/，剔掉 src 后必然全断
#   fink/debs/ 目录本身       必须留，否则 finx install 无处建链
#
# 全程离线，不需要 root。

set -u

HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
REPO=$(cd "$HERE/.." && pwd) || exit 1
PACKER=$REPO/scripts/make_seed.sh
INSTALL=$REPO/finx-install/install.sh

BASE=$(mktemp -d "${TMPDIR:-/tmp}/finx-seed-test.XXXXXX") || exit 1
# install.sh 会把测试根解析成物理路径（/tmp 在 macOS 是 /private/tmp 的链接），
# 所以断言里也要用物理路径，否则两边永远对不上。
BASE=$(cd "$BASE" && pwd -P) || exit 1
trap 'rm -rf "$BASE"' EXIT

failed=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; failed=$((failed + 1)); }

PREFIX=$BASE/fake/opt/finx
OUT=$BASE/out

# ---- 1. 造一棵假前缀，故意带上所有该被剔掉的东西 -------------------------

mkdir -p "$PREFIX/bin" "$PREFIX/var/lib/dpkg" "$PREFIX/etc" \
    "$PREFIX/src/x" "$PREFIX/var/log" "$PREFIX/fink/debs" "$PREFIX/share/doc"
printf '#!/bin/sh\nexit 0\n' > "$PREFIX/bin/finx"
chmod 755 "$PREFIX/bin/finx"
printf 'Package: finx\nStatus: install ok installed\n' > "$PREFIX/var/lib/dpkg/status"
printf 'Basepath: /opt/finx\n' > "$PREFIX/etc/finx.conf"
printf 'junk\n' > "$PREFIX/src/x/junk"
printf 'log\n' > "$PREFIX/var/log/build.log"
printf 'keep\n' > "$PREFIX/share/doc/keep.txt"
ln -s /nonexistent/finx/debs/gone.deb "$PREFIX/fink/debs/gone.deb"

# ---- 2. 打包 --------------------------------------------------------------

if "$PACKER" --prefix "$PREFIX" --out "$OUT" --release 9.9.9 --arch "$(uname -m)" \
        >"$BASE/pack.log" 2>&1; then
    pass "make_seed.sh packs a prefix"
else
    fail "make_seed.sh failed; see $BASE/pack.log"
    sed 's/^/     /' "$BASE/pack.log"
    printf '\nFAILED (%s)\n' "$BASE"
    exit 1
fi

SEED=$OUT/seed.tar.gz
MANIFEST=$OUT/manifest
[ -f "$SEED" ] && pass "seed.tar.gz exists" || fail "no seed.tar.gz"
[ -f "$MANIFEST" ] && pass "manifest exists" || fail "no manifest"

# ---- 3. 清单里的 size 与 sha256 必须与产物一致 ----------------------------

want_size=$(wc -c < "$SEED" | tr -d ' ')
got_size=$(awk '$1 == "size" { print $2 }' "$MANIFEST")
[ "$got_size" = "$want_size" ] \
    && pass "manifest size matches the archive" \
    || fail "manifest says $got_size bytes, archive is $want_size"

want_sha=$(shasum -a 256 "$SEED" | awk '{print $1}')
got_sha=$(awk '$1 == "sha256" { print $2 }' "$MANIFEST")
[ "$got_sha" = "$want_sha" ] \
    && pass "manifest sha256 matches the archive" \
    || fail "manifest sha256 does not match the archive"

[ "$(awk '$1 == "schema" { print $2 }' "$MANIFEST")" = "1" ] \
    && pass "manifest schema is 1" || fail "manifest schema is not 1"
[ "$(awk '$1 == "release" { print $2 }' "$MANIFEST")" = "9.9.9" ] \
    && pass "manifest records the release" || fail "manifest lost the release"

# ---- 4. 该剔的剔干净，该留的留住 ------------------------------------------

members=$(tar -tzf "$SEED")

want_gone='src/junk
var/log/build.log
etc/finx.conf
fink/debs/gone.deb'
echo "$want_gone" | while IFS= read -r p; do
    case $members in
        *"$p"*) printf 'FAIL %s should not be in the seed\n' "$p" ;;
    esac
done > "$BASE/gone"
if [ -s "$BASE/gone" ]; then
    cat "$BASE/gone"; failed=$((failed + 1))
else
    pass "build junk and the stale config stay out of the seed"
fi

case $members in
    *"fink/debs/"*) pass "fink/debs survives as an entry" ;;
    *) fail "fink/debs is missing; finx install would have nowhere to link" ;;
esac

[ "$(tar -tvzf "$SEED" | awk '$NF == "fink/debs/" { print substr($1, 1, 1) }')" = "d" ] \
    && pass "fink/debs is a directory, not a symlink" \
    || fail "fink/debs is not a plain directory"

case $members in
    *"share/doc/keep.txt"*) pass "ordinary payload is kept" ;;
    *) fail "share/doc/keep.txt went missing" ;;
esac

# ---- 5. 装一遍，确认解出来的树和配置都对 ----------------------------------

if FINX_TEST=$BASE/root "$INSTALL" --seed-dir="$OUT" >"$BASE/install.log" 2>&1; then
    pass "install.sh installs from the produced seed"
else
    fail "install.sh failed on the produced seed; see $BASE/install.log"
    tail -20 "$BASE/install.log" | sed 's/^/     /'
fi

ROOT=$BASE/root/opt/finx
[ -x "$ROOT/bin/finx" ] && pass "the installed prefix has bin/finx" \
    || fail "the installed prefix has no bin/finx"
[ -d "$ROOT/fink/debs" ] && pass "the installed prefix has fink/debs" \
    || fail "the installed prefix has no fink/debs"

if [ -f "$ROOT/etc/finx.conf" ]; then
    if grep -qx "Basepath: $ROOT" "$ROOT/etc/finx.conf"; then
        pass "finx.conf points at the prefix it was installed into"
    else
        fail "finx.conf does not point at $ROOT:"
        sed 's/^/     /' "$ROOT/etc/finx.conf"
    fi
else
    fail "the installer wrote no etc/finx.conf"
fi

printf '\n'
if [ "$failed" -eq 0 ]; then
    printf 'PASS: seed round trip is intact\n'
    exit 0
fi
printf 'FAIL: %s check(s) failed (sandbox %s)\n' "$failed" "$BASE"
exit 1
