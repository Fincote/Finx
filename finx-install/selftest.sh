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
# finx-install/selftest.sh - 用 FINX_TEST 沙箱验证安装器本身
#
# 全程不联网、不写真实目录：所有产物都落在 $FINX_TEST 里。
# 断言覆盖目录模式、管道模式、重复安装、越界前缀、校验失败五种情况。
#
# 用法：
#   ./finx-install/selftest.sh                             自建临时测试根，跑完删除
#   FINX_TEST=/tmp/finx-check ./finx-install/selftest.sh    用指定测试根，结果保留

set -u
set -o pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
INSTALL=$HERE/install.sh

FINX_TEST_OWNED=0
if [ -z "${FINX_TEST:-}" ]; then
    FINX_TEST=$(mktemp -d "${TMPDIR:-/tmp}/finx-selftest.XXXXXX") || exit 1
    FINX_TEST_OWNED=1
fi

case $FINX_TEST in
    /*) ;;
    *) printf 'ERROR: FINX_TEST must be an absolute path\n' >&2; exit 1 ;;
esac

mkdir -p "$FINX_TEST" || exit 1
ROOT=$(cd -- "$FINX_TEST" && pwd -P) || exit 1

cleanup() {
    [ "$FINX_TEST_OWNED" -eq 1 ] && rm -rf "$ROOT"
}
trap cleanup EXIT

export FINX_TEST

failures=0
pass() {
    printf 'ok   %s\n' "$*"
}
failed() {
    printf 'FAIL %s\n' "$*"
    failures=$((failures + 1))
}

check_ok() {
    label=$1
    shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else failed "$label"; fi
}

check_fails() {
    label=$1
    shift
    if "$@" >/dev/null 2>&1; then failed "$label (expected a non-zero exit)"; else pass "$label"; fi
}

# ---- 造一个假种子，结构足以走完七个阶段 ----------------------------------

SEED=$ROOT/seed
mkdir -p "$SEED/bin" "$SEED/lib/finx" "$SEED/etc" || exit 1

cat > "$SEED/bin/finx" <<'STUB'
#!/bin/sh
case "$1" in
    scanpackages) echo "stub: finx scanpackages"; exit 0 ;;
    *) echo "stub finx $*"; exit 0 ;;
esac
STUB
chmod 755 "$SEED/bin/finx"

# 安装器收尾会提示 source 它，假种子也得有，否则那句提示对不上真实产物
cat > "$SEED/bin/init.sh" <<'STUB'
# stub init.sh for the selftest sandbox
STUB
chmod 755 "$SEED/bin/init.sh"

printf 'Debian dpkg version 1.19.7 (stub)\n' > "$SEED/bin/dpkg-stub"
chmod 755 "$SEED/bin/dpkg-stub"
echo "0.46.0" > "$SEED/lib/finx/version"
printf 'placeholder\n' > "$SEED/etc/seed.txt"

# 放一个真的 Mach-O 进去，否则 resign_macho 只是在空转（re-signed 0）。
# 没有可用的 cc 就跳过随之而来的两条断言，而不是假装通过。
EXPECT_MACHO=0
if command -v cc >/dev/null 2>&1; then
    printf 'int main(void){return 0;}\n' > "$ROOT/probe.c"
    if cc -o "$SEED/bin/hello" "$ROOT/probe.c" 2>/dev/null; then
        EXPECT_MACHO=1
    fi
fi

tar -czf "$ROOT/seed.tar.gz" -C "$SEED" . || exit 1
SEED_SIZE=$(wc -c < "$ROOT/seed.tar.gz" | tr -d ' ')
SEED_SHA=$(shasum -a 256 "$ROOT/seed.tar.gz" | awk '{print $1}')
HOST_ARCH=$(uname -m)

write_manifest() {
    printf 'schema 1\nrelease 0.46.0\narch %s\nseed seed.tar.gz\nsize %s\nsha256 %s\n' \
        "$HOST_ARCH" "$SEED_SIZE" "$SEED_SHA" > "$1"
}

write_manifest "$ROOT/manifest"

LOG=$ROOT/last-install.log

printf '== selftest: FINX_TEST=%s\n\n' "$ROOT"
if [ "$EXPECT_MACHO" -eq 1 ]; then
    printf '   (fake seed carries a compiled Mach-O)\n\n'
else
    printf '   (no cc available; re-signing assertions will be skipped)\n\n'
fi

# ---- 1. --help 退出 0 且不创建前缀 ---------------------------------------

"$INSTALL" --help >"$LOG" 2>&1 \
    || failed "--help exits non-zero"
[ ! -e "$ROOT/opt/finx" ] && pass "--help created nothing" || failed "--help created $ROOT/opt/finx"
grep -q -- '--seed-dir' "$LOG" && pass "--help lists --seed-dir" || failed "--help is missing --seed-dir"

# ---- 2. 默认前缀落在测试根内 --------------------------------------------

if "$INSTALL" --seed-dir="$ROOT" >"$LOG" 2>&1; then
    pass "install with default prefix"
else
    failed "install with default prefix"
fi

if [ -f "$ROOT/opt/finx/bin/finx" ]; then
    pass "seed extracted into the test root"
else
    failed "seed not extracted into the test root"
fi

if [ -f "$ROOT/opt/finx/bin/init.sh" ]; then
    pass "init.sh the closing message points at really exists"
else
    failed "closing message points at a missing init.sh"
fi

# 重签名：假种子里有真 Mach-O 时才断言，否则明说跳过
if [ "$EXPECT_MACHO" -eq 1 ]; then
    if grep -q 're-signed 1 Mach-O' "$LOG"; then
        pass "the Mach-O in the seed was actually re-signed"
    else
        failed "resign_macho did not touch the compiled Mach-O"
    fi
    if codesign -v "$ROOT/opt/finx/bin/hello" >/dev/null 2>&1; then
        pass "re-signed binary verifies"
    else
        failed "re-signed binary does not verify"
    fi
else
    printf 'skip re-signing assertions (no cc available)\n'
fi

if grep -qx "Basepath: $ROOT/opt/finx" "$ROOT/opt/finx/etc/finx.conf" 2>/dev/null; then
    pass "finx.conf records the sandbox prefix"
else
    failed "finx.conf does not record the sandbox prefix"
fi

# ---- 3. 重复安装必须被拒 -------------------------------------------------

check_fails "re-install without --force is refused" \
    "$INSTALL" --seed-dir="$ROOT"

# ---- 4. 越界前缀必须被拒（含 .. 逃逸与符号链接） -------------------------

check_fails "--prefix outside FINX_TEST is refused" \
    "$INSTALL" --seed-dir="$ROOT" --prefix="$ROOT/../finx-escape"

mkdir -p "$ROOT/outside-target"
ln -sfn /tmp "$ROOT/link-out" 2>/dev/null
check_fails "--prefix through a symlink is still confined" \
    "$INSTALL" --seed-dir="$ROOT" --prefix="$ROOT/link-out/finx-selftest-escape"

# ---- 5. 校验失败必须中止且不留目录 --------------------------------------

BAD=$ROOT/bad
mkdir -p "$BAD"
cp "$ROOT/seed.tar.gz" "$BAD/" || exit 1
printf 'schema 1\nrelease 0.46.0\narch %s\nseed seed.tar.gz\nsize %s\nsha256 %s\n' \
    "$HOST_ARCH" "$SEED_SIZE" "0000000000000000000000000000000000000000000000000000000000000000" \
    > "$BAD/manifest"

check_fails "sha256 mismatch is refused" \
    "$INSTALL" --seed-dir="$BAD" --prefix="$ROOT/tampered"
[ ! -e "$ROOT/tampered" ] && pass "failed verification left no directory" \
    || failed "failed verification left $ROOT/tampered behind"

# ---- 6. 管道模式 ---------------------------------------------------------

if cat "$HERE/install.sh" | /bin/bash -s -- --seed-dir="$ROOT" --prefix="$ROOT/piped" >/dev/null 2>&1; then
    pass "piped standalone install"
else
    failed "piped standalone install"
fi
[ -f "$ROOT/piped/bin/finx" ] && pass "piped install landed in the sandbox" \
    || failed "piped install did not land in the sandbox"

# ---- 7. 单文件必须与源同步 ----------------------------------------------

check_ok "install.sh is not stale" "$HERE/build-bundle.sh" --check

# ---- 8. 源码回落 ---------------------------------------------------------

SRCROOT=$ROOT/fake-src
mkdir -p "$SRCROOT/Finx-main" || exit 1
cat > "$SRCROOT/Finx-main/bootstrap" <<'STUB'
#!/bin/bash
set -e
prefix=$1
mkdir -p "$prefix/bin"
printf '#!/bin/sh\nexit 0\n' > "$prefix/bin/finx"
chmod 755 "$prefix/bin/finx"
printf 'ran %s\n' "$prefix" > "$prefix/marker"
STUB
chmod 755 "$SRCROOT/Finx-main/bootstrap"
echo "0.46.0-stub" > "$SRCROOT/Finx-main/VERSION"
tar -czf "$ROOT/finx-src.tar.gz" -C "$SRCROOT" Finx-main || exit 1

if "$INSTALL" --from-source --source-url="file://$ROOT/finx-src.tar.gz" \
        --prefix="$ROOT/fromsource" >"$LOG" 2>&1; then
    pass "--from-source builds from the source archive"
else
    failed "--from-source failed"
fi

if [ -s "$ROOT/fromsource/marker" ]; then
    pass "bootstrap received the requested prefix"
else
    failed "bootstrap did not run, or ran with the wrong prefix"
fi

# 真归档、但缺 bootstrap：用来确认「内容检查」而不是「解包失败」拦住了它
mkdir -p "$SRCROOT/Finx-empty" || exit 1
echo "0.46.0-stub" > "$SRCROOT/Finx-empty/VERSION"
tar -czf "$ROOT/finx-noboot.tar.gz" -C "$SRCROOT" Finx-empty || exit 1

check_fails "a source archive without bootstrap is refused" \
    "$INSTALL" --from-source --source-url="file://$ROOT/finx-noboot.tar.gz" --prefix="$ROOT/noboot"

# 显式指定了来源时不回落：--no-fallback 且探不到种子必须失败
check_fails "--no-fallback refuses a missing seed" \
    "$INSTALL" --no-fallback --manifest-url="file://$ROOT/missing/manifest" --prefix="$ROOT/strict"

# ---- 9. 多镜像回退（用 file:// 离线模拟真实下载路径） -------------------

MIRROR=$ROOT/mirror
mkdir -p "$MIRROR" || exit 1
cp "$ROOT/seed.tar.gz" "$MIRROR/" || exit 1
{
    printf 'schema 1\nrelease 0.46.0\narch %s\nseed seed.tar.gz\nsize %s\nsha256 %s\n' \
        "$HOST_ARCH" "$SEED_SIZE" "$SEED_SHA"
    printf 'url file://%s/missing/seed.tar.gz\n' "$ROOT"
    printf 'url file://%s/seed.tar.gz\n' "$MIRROR"
} > "$MIRROR/manifest"

if "$INSTALL" --manifest-url="file://$MIRROR/manifest" --prefix="$ROOT/replica" >"$LOG" 2>&1; then
    pass "manifest-url install falls back to the second mirror"
else
    failed "manifest-url install failed"
fi

if grep -q 'mirror failed' "$LOG"; then
    pass "dead mirror was reported and skipped"
else
    failed "dead mirror was not reported"
fi

if [ -f "$ROOT/replica/bin/finx" ]; then
    pass "downloaded seed landed in the sandbox"
else
    failed "downloaded seed did not land in the sandbox"
fi

# 清单本身取不到时必须中止，而不是拿个空文件继续
check_fails "unreachable manifest is refused" \
    "$INSTALL" --manifest-url="file://$ROOT/missing/manifest" --prefix="$ROOT/nomanifest"

# ---- 收尾的 PATH 写入 ----------------------------------------------------
#
# 安装器的收尾会往 shell 启动文件里追加一行。这件事在主流程里被 FINX_TEST
# 挡掉了（沙箱不许碰真的 $HOME），所以在这里用假 HOME 单独测：
# 写对文件、重复运行不重复追加、--no-path 不写。

FAKEHOME="$ROOT/fakehome"
mkdir -p "$FAKEHOME"

path_probe() {
    # 只取安装器里那几个函数，不执行 main
    awk '/^target_home\(\) \{/,/^\}/' "$INSTALL"
    awk '/^login_shell_name\(\) \{/,/^\}/' "$INSTALL"
    awk '/^shell_rc_path\(\) \{/,/^\}/' "$INSTALL"
    awk '/^shell_source_line\(\) \{/,/^\}/' "$INSTALL"
    awk '/^print_path_help\(\) \{/,/^\}/' "$INSTALL"
    awk '/^setup_path\(\) \{/,/^\}/' "$INSTALL"
}

HOME="$FAKEHOME" SHELL=/bin/zsh PREFIX="$ROOT/opt/finx" NO_PATH=0 \
    sh -c "$(path_probe); info(){ :; }; warn(){ echo WARN: \"$*\" >&2; }; setup_path" \
    >/dev/null 2>&1
if grep -qF "test -r $ROOT/opt/finx/bin/init.sh" "$FAKEHOME/.zprofile" 2>/dev/null; then
    pass "installer puts finx on PATH in .zprofile"
else
    failed "installer did not write the PATH line"
fi

before=$(wc -l < "$FAKEHOME/.zprofile" 2>/dev/null || echo 0)
HOME="$FAKEHOME" SHELL=/bin/zsh PREFIX="$ROOT/opt/finx" NO_PATH=0 \
    sh -c "$(path_probe); info(){ :; }; warn(){ :; }; setup_path" >/dev/null 2>&1
after=$(wc -l < "$FAKEHOME/.zprofile" 2>/dev/null || echo 0)
if [ "$before" = "$after" ]; then
    pass "rerunning does not append the PATH line twice"
else
    failed "PATH line was appended again ($before -> $after)"
fi

rm -f "$FAKEHOME/.zprofile"
HOME="$FAKEHOME" SHELL=/bin/zsh PREFIX="$ROOT/opt/finx" NO_PATH=1 \
    sh -c "$(path_probe); info(){ :; }; warn(){ :; }; setup_path" >/dev/null 2>&1
if [ ! -f "$FAKEHOME/.zprofile" ]; then
    pass "--no-path leaves the shell configuration untouched"
else
    failed "--no-path still wrote to the shell configuration"
fi

# ---- 下载源的环境变量 ----------------------------------------------------
#
# 三个 *_DOMAIN 变量必须：只认 https/file、去掉末尾斜杠、报错带变量名。
# 这三条都是照搬 MacWave 的做法，任何一条失效都会让自建镜像的人踩坑。

domain_ok() {
    FINX_INDEX_DOMAIN="$1" FINX_SEED_DOMAIN=https://ok.example \
        FINX_SOURCE_DOMAIN=https://ok.example \
        sh -c '. "$1/finx-install/lib/common.sh"; printf "%s\n" "$FINX_INDEX_DOMAIN"' _ "$HERE/.."
}

if [ "$(domain_ok 'https://mirror.example/finx/')" = "https://mirror.example/finx" ]; then
    pass "domain value is normalized (trailing slash dropped)"
else
    failed "domain normalization did not strip the trailing slash"
fi

if [ "$(domain_ok 'file:///srv/finx')" = "file:///srv/finx" ]; then
    pass "file:// domains are accepted"
else
    failed "file:// domain was rejected or altered"
fi

out=$(domain_ok 'http://evil.example/finx' 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FINX_INDEX_DOMAIN'; then
    pass "plain http is refused and the error names the variable"
else
    failed "plain http was accepted, or the error did not name the variable"
fi

if [ "$(domain_ok 'http://127.0.0.1:8080/finx')" = "http://127.0.0.1:8080/finx" ]; then
    pass "loopback http is allowed for offline testing"
else
    failed "loopback http was refused"
fi

out=$(FINX_CONNECT_TIMEOUT=abc sh -c '. "$1/finx-install/lib/common.sh"' _ "$HERE/.." 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FINX_CONNECT_TIMEOUT'; then
    pass "a non-numeric FINX_CONNECT_TIMEOUT is refused"
else
    failed "a non-numeric FINX_CONNECT_TIMEOUT was accepted"
fi

out=$(FINX_CONNECT_TIMEOUT=7 sh -c '. "$1/finx-install/lib/common.sh"; printf "%s" "$FINX_CONNECT_TIMEOUT"' _ "$HERE/.." 2>&1)
if [ "$out" = "7" ]; then
    pass "FINX_CONNECT_TIMEOUT is honoured"
else
    failed "FINX_CONNECT_TIMEOUT was ignored (got: $out)"
fi

# ---- run_bootstrap 的两条路径 --------------------------------------------
#
# 不用真 sudo、不用真 bootstrap：把 lib 直接 source 进来，用桩替换外部依赖。
# 这里守的是两个「看不见的」东西：
#
#   1. sudo_cmd 为空时不能炸。以 root 运行（最常见的 `sudo ./install.sh`）或
#      测试根里，那个数组是空的，而 bash 3.2 在 set -u 下展开空数组会报
#      unbound variable —— 4.4 才修好。
#   2. 代理变量必须穿过 sudo。sudo 默认重置环境，不转发的话，配了代理的用户
#      会在源码自举的下载阶段卡住，而 curl 明明是通的。

cat > "$ROOT/run_bootstrap_probe.sh" <<'PROBE'
set -u -o pipefail
. "$1/finx-install/lib/common.sh"
. "$1/finx-install/lib/detect.sh"
. "$1/finx-install/lib/manifest.sh"
. "$1/finx-install/lib/extract.sh"
. "$1/finx-install/lib/source.sh"
SOURCE_ROOT=$2
target=/nowhere
require_bootstrap_prerequisites() { :; }
info() { :; }
die() { echo "die: $*" >&2; exit 1; }
have() { return 0; }
# 桩 sudo：-v 直接成功，其余原样执行（env VAR=... 那层由真的 env 处理）。
sudo() {
    if [ "${1:-}" = "-v" ]; then return 0; fi
    printf 'sudo-call: %s\n' "$*"
    "$@"
}
if [ "${PROBE_ROOT:-0}" -eq 1 ]; then
    # 冒充 root：sudo_cmd 保持为空，正是 sudo ./install.sh 的情形
    id() { if [ "$1" = "-u" ]; then echo 0; else command id "$@"; fi; }
fi
run_bootstrap "$target"
PROBE

mkdir -p "$ROOT/stub-src"
printf '#!/bin/bash\necho "BOOTSTRAP RAN $*"\n' > "$ROOT/stub-src/bootstrap"
chmod +x "$ROOT/stub-src/bootstrap"

# bash 3.2 在 set -u 下展开空数组会报 unbound variable；以 root 运行和测试根里
# sudo_cmd 正好为空，这条路径不测就发现不了。
if out=$(PROBE_ROOT=1 /bin/bash "$ROOT/run_bootstrap_probe.sh" "$HERE/.." "$ROOT/stub-src" 2>&1) \
        && printf '%s' "$out" | grep -q 'BOOTSTRAP RAN'; then
    pass "run_bootstrap works when there is no sudo to prefix"
else
    failed "run_bootstrap broke with an empty sudo_cmd: $out"
fi

# sudo 默认重置环境；不显式转发，配了代理的用户会卡在源码自举的下载阶段。
if out=$(http_proxy=http://p.example:1 https_proxy=http://p.example:1 \
        /bin/bash "$ROOT/run_bootstrap_probe.sh" "$HERE/.." "$ROOT/stub-src" 2>&1) \
        && printf '%s' "$out" | grep -q 'env http_proxy=http://p.example:1 https_proxy=http://p.example:1' \
        && printf '%s' "$out" | grep -q 'BOOTSTRAP RAN'; then
    pass "proxy variables are passed through sudo"
else
    failed "proxy variables did not reach the bootstrap command: $out"
fi

# ---- 汇总 ---------------------------------------------------------------

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS: all checks green (sandbox %s)\n' "$ROOT"
    exit 0
fi
printf 'FAIL: %d check(s) failed (sandbox %s)\n' "$failures" "$ROOT"
exit 1
