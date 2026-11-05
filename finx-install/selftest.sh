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
# 断言覆盖目录模式、管道模式、重复安装、越界前缀、校验失败五种情况，
# 外加试运行完全不碰网络（假 curl 记账，一次都不许被调用）。
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

# 安装器会拒绝缺少 dpkg 的种子：真实事故里 bootstrap 第三阶段中断，种子没有
# bin/dpkg，装出来是个死目录，而安装器照样报成功。
for tool in dpkg dpkg-deb; do
    printf '#!/bin/sh\nexit 0\n' > "$SEED/bin/$tool"
    chmod 755 "$SEED/bin/$tool"
done

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

# ---- 2b. 已有安装 / 不像 finx 的前缀，都不该挡住试运行 ----------------
#
# 开发者机器上本来就有一份 /opt/finx，这是常态。check_target 若在 dry_run 下
# 也 die，在这台机器上写 finx 的人就永远看不到自己的计划。

if "$INSTALL" --dry-run --seed-dir="$ROOT" >"$ROOT/dry-existing.log" 2>&1; then
    pass "--dry-run is not blocked by an existing installation"
else
    failed "--dry-run refused an existing installation: $(tail -2 "$ROOT/dry-existing.log" 2>/dev/null)"
fi

mkdir -p "$ROOT/junk-prefix" || exit 1
printf 'not a finx install\n' > "$ROOT/junk-prefix/stray-file"
if "$INSTALL" --dry-run --seed-dir="$ROOT" --prefix="$ROOT/junk-prefix" \
        >"$ROOT/dry-junk.log" 2>&1; then
    pass "--dry-run is not blocked by a non-Finx directory"
else
    failed "--dry-run refused a non-Finx prefix: $(tail -2 "$ROOT/dry-junk.log" 2>/dev/null)"
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

# ---- 4b. 沙箱外只认 /opt/finx ------------------------------------------
#
# 这不是「装错地方」的问题。安装器有两条会大量删改内容的路径：解包会覆盖同名
# 文件，符号链接围栏失败时会清空前缀的顶层内容。指着 /usr/local 跑一遍，
# 代价是整份 Homebrew —— 先被覆盖，再被 chown -R root:wheel 接管。
#
# 判定必须按物理路径做。--prefix=/opt/../usr/local 在字符串上看着无害，
# 实际落在 /usr/local；符号链接同理。

for bad in /usr/local /opt /etc /usr/local/finx /opt/../usr/local "$HOME"; do
    if env -u FINX_TEST "$INSTALL" --prefix="$bad" --accept-license >/dev/null 2>&1; then
        failed "prefix $bad was accepted outside the sandbox"
    else
        pass "prefix $bad is refused outside the sandbox"
    fi
done

ln -sfn /usr/local "$ROOT/link-system" 2>/dev/null
if env -u FINX_TEST "$INSTALL" --prefix="$ROOT/link-system" --accept-license >/dev/null 2>&1; then
    failed "a symlink to /usr/local was accepted as a prefix"
else
    pass "a symlink to /usr/local is refused as a prefix"
fi

# 归一化之后确实是 /opt/finx 的写法仍要放行，否则守卫会变成「不许写 ..」这种
# 与真正意图无关的规则。
if [ "$(env -u FINX_TEST PREFIX=/opt/../opt/finx bash -c 'FINX_SOURCE_ONLY=1; . "$1/install.sh"; enforce_prefix_policy; printf "%s" "$PREFIX"' _ "$HERE")" = /opt/finx ]; then
    pass "/opt/../opt/finx canonicalises to /opt/finx and is allowed"
else
    failed "/opt/../opt/finx should be accepted after canonicalisation"
fi

# ---- 4c. 凭据不能出现在输出里 ------------------------------------------
#
# 镜像可以带账号（FINX_SEED_DOMAIN=https://user:pass@mirror/...），而安装器会把
# 地址打印出来。终端输出会进 CI 日志、截图、issue —— 密码就跟着走了。

r_out=$(bash -c 'FINX_SOURCE_ONLY=1; . "$1/install.sh"; redact_url "https://alice:s3cret@mirror.example/x"' _ "$HERE")
if [ "$r_out" = "https://***:***@mirror.example/x" ]; then
    pass "redact_url masks the userinfo and keeps the host"
else
    failed "redact_url did not mask a credential-bearing URL"
fi

r_out=$(bash -c 'FINX_SOURCE_ONLY=1; . "$1/install.sh"; redact_url "https://mirror.example/x"' _ "$HERE")
if [ "$r_out" = "https://mirror.example/x" ]; then
    pass "redact_url leaves a URL without credentials alone"
else
    failed "redact_url mangled a URL that has no credentials"
fi

r_out=$(bash -c 'FINX_SOURCE_ONLY=1; . "$1/install.sh"; redact_url "file:///tmp/seed/manifest"' _ "$HERE")
if [ "$r_out" = "file:///tmp/seed/manifest" ]; then
    pass "redact_url leaves a file: URL alone"
else
    failed "redact_url mangled a file: URL"
fi

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

# ---- 6. 载荷里的越界符号链接必须被拒 ------------------------------------

# 解包工具只过滤成员**名字**里的 "../"，与链接的**目标**无关。于是一个种子可以
# 老实躺在树内，却指向 /usr/local/... —— 装完之后 resign_macho 会走遍整棵树，
# 卸载时的 rm -rf 也会顺着它出去。同一份种子里再放一个树内相对链接和一个指向
# /usr/bin 的链接，用来确认防线区分的是「在不在树内」，不是「像不像系统路径」。
LINK_BAD=$ROOT/linkbad
mkdir -p "$LINK_BAD"
cp -R "$SEED" "$LINK_BAD/seed" || exit 1
ln -s /usr/local/test/test_write "$LINK_BAD/seed/lib/evil_write"
ln -s 15.0 "$LINK_BAD/seed/lib/ok_rel"
ln -s /usr/bin/true "$LINK_BAD/seed/lib/ok_system"
tar -czf "$LINK_BAD/seed.tar.gz" -C "$LINK_BAD/seed" . || exit 1
printf 'schema 1\nrelease 0.46.0\narch %s\nseed seed.tar.gz\nsize %s\nsha256 %s\n' \
    "$HOST_ARCH" "$(wc -c < "$LINK_BAD/seed.tar.gz" | tr -d ' ')" \
    "$(shasum -a 256 "$LINK_BAD/seed.tar.gz" | awk '{print $1}')" > "$LINK_BAD/manifest"

LINK_LOG=$ROOT/linkbad.log
if "$INSTALL" --seed-dir="$LINK_BAD" --prefix="$ROOT/linkbad-target" >"$LINK_LOG" 2>&1; then
    failed "a seed with a link escaping the prefix was accepted"
else
    pass "a seed with a link escaping the prefix is refused"
fi

if grep -q 'lib/evil_write -> /usr/local/test/test_write' "$LINK_LOG" \
    && ! grep -q 'ok_rel' "$LINK_LOG" && ! grep -q 'ok_system' "$LINK_LOG" \
    && grep -q 'Only these locations are exempt' "$LINK_LOG"; then
    pass "the refusal names the offending link only, plus the exempt list"
else
    failed "the refusal did not name exactly the offending link"
fi

[ -z "$(ls -A "$ROOT/linkbad-target" 2>/dev/null)" ] \
    && pass "the refused seed left an empty prefix" \
    || failed "the refused seed left content in $ROOT/linkbad-target"

# ---- 7. 管道模式 ---------------------------------------------------------

if cat "$HERE/install.sh" | /bin/bash -s -- --seed-dir="$ROOT" --prefix="$ROOT/piped" >/dev/null 2>&1; then
    pass "piped standalone install"
else
    failed "piped standalone install"
fi
[ -f "$ROOT/piped/bin/finx" ] && pass "piped install landed in the sandbox" \
    || failed "piped install did not land in the sandbox"

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

# ---- 10. 种子与主机不匹配时回退源码 --------------------------------------
#
# 清单存在不等于种子能用：种子是按 arch 与 darwin 构建的。自动发现那条路上，
# 碰到「有清单但这份种子装不进来」应当退回源码并说明原因，而不是在
# resolve_manifest 里直接 die。
#
# 真实症状：Intel 机器在 macOS 15 上跑安装器，探到了为 arm64 构建的 seed-24，
# 然后只拿到一句 "seed is built for arm64 but this host is x86_64" 就结束了 ——
# 用户要的是装上 Finx，不是一条错误信息。

WRONG_ARCH=x86_64
[ "$HOST_ARCH" = "x86_64" ] && WRONG_ARCH=arm64
FOREIGN=$ROOT/foreign
mkdir -p "$FOREIGN" || exit 1
cp "$ROOT/seed.tar.gz" "$FOREIGN/" || exit 1
printf 'schema 1\nrelease 0.46.0\narch %s\nseed seed.tar.gz\nsize %s\nsha256 %s\n' \
    "$WRONG_ARCH" "$SEED_SIZE" "$SEED_SHA" > "$FOREIGN/manifest"

FBLOG=$ROOT/fallback.log
if FINX_INDEX_DOMAIN="file://$FOREIGN" \
        "$INSTALL" --source-url="file://$ROOT/finx-src.tar.gz" \
        --prefix="$ROOT/fallback" >"$FBLOG" 2>&1; then
    pass "a seed built for another architecture falls back to source"
else
    failed "a seed built for another architecture did not fall back"
fi

if [ -s "$ROOT/fallback/marker" ]; then
    pass "the fallback actually ran bootstrap"
else
    failed "the fallback did not run bootstrap"
fi

if grep -q "seed is built for $WRONG_ARCH" "$FBLOG"; then
    pass "the unusable seed is named in the warning"
else
    failed "the warning did not name the unusable seed"
fi

# 显式指定来源时不换路：调用方说了用这份，静默换源会让校验失去意义。
check_fails "an explicit seed for another architecture is still refused" \
    "$INSTALL" --manifest-url="file://$FOREIGN/manifest" --prefix="$ROOT/foreign-explicit"

# ---- 11. 本机没有种子时往下找更老的一份 --------------------------------
#
# 二进制记的是构建时的 Darwin，低处编的能在高处跑、反之不行（docs/MIRRORS.md
# 三点六）。所以 macOS 14（Darwin 23）上没有 seed-23 时，seed-21 完全可用。
# 只认精确匹配的话，这些用户会被无谓地送去源码编译半小时 —— 而他们本不必。
#
# 用 file:// 当基址，造出「23 和 22 都没有、21 有」的布局。

SLOW=$ROOT/seeds-low
mkdir -p "$SLOW/seed-21" || exit 1
cp "$ROOT/seed.tar.gz" "$SLOW/seed-21/" || exit 1
cp "$ROOT/manifest"    "$SLOW/seed-21/" || exit 1

LOWLOG=$ROOT/lowseed.log
# 还得给 FINX_SEED_DOMAIN：清单里没有 url 行时种子从那里取，否则会去真实网络。
if FINX_SEED_BASE="file://$SLOW" FINX_SEED_DOMAIN="file://$SLOW/seed-21" \
        FINX_LOWEST_SEED_DARWIN=21 \
        "$INSTALL" --prefix="$ROOT/lowered" >"$LOWLOG" 2>&1; then
    pass "a system without its own seed uses an older build"
else
    failed "the downward search did not find seed-21"
fi

if [ -f "$ROOT/lowered/bin/finx" ]; then
    pass "the older seed installed into the sandbox"
else
    failed "the older seed did not install"
fi

if grep -q 'seed-21' "$LOWLOG"; then
    pass "the log names the seed it settled on"
else
    failed "the log does not say which seed was used"
fi

# 一份都没有时仍然回退源码，而且不该试到 21 以下
EMPTY=$ROOT/seeds-none
mkdir -p "$EMPTY" || exit 1
NONELOG=$ROOT/noseed.log
if FINX_SEED_BASE="file://$EMPTY" FINX_SEED_DOMAIN="file://$EMPTY" \
        FINX_LOWEST_SEED_DARWIN=21 \
        "$INSTALL" --source-url="file://$ROOT/finx-src.tar.gz" \
        --prefix="$ROOT/noseed" >"$NONELOG" 2>&1; then
    pass "with no seed at any level the source path takes over"
else
    failed "the source fallback did not run when no seed exists"
fi

if [ -s "$ROOT/noseed/marker" ]; then
    pass "bootstrap ran after exhausting the seeds"
else
    failed "bootstrap did not run after exhausting the seeds"
fi

# ---- 12. 多镜像回退（用 file:// 离线模拟真实下载路径） -------------------

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

# ---- 收尾的 PATH 提示 ----------------------------------------------------
#
# 安装器**不写**用户的启动文件，也没有 --path 这样的开关。收尾只打印一条
# 用户可以自己执行的命令（`echo '...' >> ~/.zprofile`）。这里断言三件事：
# 选对文件、打印出来的那一行内容对、以及源文件里确实没有任何写文件的代码。

FAKEHOME="$ROOT/fakehome"
mkdir -p "$FAKEHOME"

path_probe() {
    # 只取安装器里那几个函数，不执行 main
    awk '/^target_home\(\) \{/,/^\}/' "$INSTALL"
    awk '/^login_shell_name\(\) \{/,/^\}/' "$INSTALL"
    awk '/^shell_rc_path\(\) \{/,/^\}/' "$INSTALL"
    awk '/^shell_source_line\(\) \{/,/^\}/' "$INSTALL"
    awk '/^shell_append_line\(\) \{/,/^\}/' "$INSTALL"
    awk '/^print_path_help\(\) \{/,/^\}/' "$INSTALL"
    awk '/^explain_path\(\) \{/,/^\}/' "$INSTALL"
}

# 哪个文件由「这个人的登录 shell」决定，而那要问 Directory Services ——
# 所以不能在测试里假设 .zprofile。这里用安装器自己的 shell_rc_path 算出来，
# 再断言打印内容里出现的是同一个文件。CI 的 runner 与本地用户 shell 不同，
# 写死文件名会在其中一边必然失败。
target_rc() {
    HOME="$FAKEHOME" SHELL=/bin/zsh sh -c "$(path_probe); shell_rc_path"
}
RC=$(target_rc)
RC_NAME=$(basename "$RC")

helptext() {
    HOME="$FAKEHOME" SHELL=/bin/zsh PREFIX="$ROOT/opt/finx" ZH="${1:-0}" \
        sh -c "$(path_probe); info(){ :; }; warn(){ :; }; explain_path" 2>&1
}

OUT=$(helptext 0)

if printf '%s' "$OUT" | grep -qF "echo 'test -r $ROOT/opt/finx/bin/init.sh && . $ROOT/opt/finx/bin/init.sh' >> $RC"; then
    pass "the installer prints a command that appends the PATH line to $RC_NAME"
else
    failed "the append command is missing or malformed (rc=$RC)"
fi

if printf '%s' "$OUT" | grep -qF ". $ROOT/opt/finx/bin/init.sh"; then
    pass "the help says how to load finx in the current shell"
else
    failed "no source line for the current shell"
fi

if printf '%s' "$OUT" | grep -qF -- "--path"; then
    failed "the help still mentions a --path flag"
else
    pass "the help does not offer to write the file for you"
fi

# 打印不该有任何副作用 —— 假 HOME 下连文件都不该出现。
if [ -z "$(ls -A "$FAKEHOME" 2>/dev/null)" ]; then
    pass "printing the help creates nothing in the fake home"
else
    failed "printing the help left files behind in $FAKEHOME"
fi

# 中文版同样要给出那条可复制的命令，而不是只说「自己配」。
if ZHTEXT=$(helptext 1) && printf '%s' "$ZHTEXT" | grep -qF ">> $RC"; then
    pass "the Chinese help carries the same append command"
else
    failed "the Chinese help has no append command"
fi

# 最后一道：源文件里不能有任何写启动文件的代码。这条是防回归，不是风格洁癖 ——
# 一旦有人把 append 加回来，卸载就得靠字符串匹配去猜用户文件里哪一行是自己写的。
if grep -qF -e 'WRITE_PATH' -e '--no-path' -e '>> "$rc"' "$INSTALL"; then
    failed "install.sh still contains code that writes a shell startup file"
else
    pass "install.sh has no code path that writes a shell startup file"
fi

# ---- 下载源的环境变量 ----------------------------------------------------
#
# 三个 *_DOMAIN 变量必须：只认 https/file、去掉末尾斜杠、报错带变量名。
# 这三条都是照搬 MacWave 的做法，任何一条失效都会让自建镜像的人踩坑。

domain_ok() {
    FINX_INDEX_DOMAIN="$1" FINX_SEED_DOMAIN=https://ok.example \
        FINX_SOURCE_DOMAIN=https://ok.example FINX_DEB_DOMAIN=https://ok.example \
        sh -c 'FINX_SOURCE_ONLY=1; . "$1/finx-install/install.sh"; printf "%s\n" "$FINX_INDEX_DOMAIN"' _ "$HERE/.."
}

# FINX_DEB_DOMAIN 与另外三个走同一套校验，但要单独确认它真的被读进来 ——
# 变量名拼错时 finx_domain 根本不会被调用，于是「设了没用」而没人发现。
deb_domain() {
    FINX_DEB_DOMAIN="$1" \
        sh -c 'FINX_SOURCE_ONLY=1; . "$1/finx-install/install.sh"; printf "%s\n" "$FINX_DEB_DOMAIN"' _ "$HERE/.."
}

if [ "$(domain_ok 'https://mirror.example/finx/')" = "https://mirror.example/finx" ]; then
    pass "domain value is normalized (trailing slash dropped)"
else
    failed "domain normalization did not strip the trailing slash"
fi

if [ "$(deb_domain 'https://mirror.example/debs/')" = "https://mirror.example/debs" ]; then
    pass "FINX_DEB_DOMAIN is read and normalized"
else
    failed "FINX_DEB_DOMAIN was not applied"
fi

if [ "$(deb_domain 'file:///srv/debs')" = "file:///srv/debs" ]; then
    pass "FINX_DEB_DOMAIN accepts file:// for offline mirrors"
else
    failed "FINX_DEB_DOMAIN rejected file://"
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

out=$(FINX_CONNECT_TIMEOUT=abc sh -c 'FINX_SOURCE_ONLY=1; . "$1/finx-install/install.sh"' _ "$HERE/.." 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FINX_CONNECT_TIMEOUT'; then
    pass "a non-numeric FINX_CONNECT_TIMEOUT is refused"
else
    failed "a non-numeric FINX_CONNECT_TIMEOUT was accepted"
fi

out=$(FINX_CONNECT_TIMEOUT=7 sh -c 'FINX_SOURCE_ONLY=1; . "$1/finx-install/install.sh"; printf "%s" "$FINX_CONNECT_TIMEOUT"' _ "$HERE/.." 2>&1)
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
FINX_SOURCE_ONLY=1; . "$1/finx-install/install.sh"
# install.sh 顶层把 VERBOSE 写成 0（刻意不听环境变量），source 之后必须显式设。
VERBOSE=${PROBE_VERBOSE:-0}
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
echo "PROBE-OK"
PROBE

mkdir -p "$ROOT/stub-src"
printf '#!/bin/bash\necho "BOOTSTRAP RAN $*"\n' > "$ROOT/stub-src/bootstrap"
chmod +x "$ROOT/stub-src/bootstrap"

# bash 3.2 在 set -u 下展开空数组会报 unbound variable；以 root 运行和测试根里
# sudo_cmd 正好为空，这条路径不测就发现不了。
if out=$(PROBE_ROOT=1 /bin/bash "$ROOT/run_bootstrap_probe.sh" "$HERE/.." "$ROOT/stub-src" 2>&1) \
        && printf '%s' "$out" | grep -q 'PROBE-OK'; then
    pass "run_bootstrap works when there is no sudo to prefix"
else
    failed "run_bootstrap broke with an empty sudo_cmd: $out"
fi

# sudo 默认重置环境；不显式转发，配了代理的用户会卡在源码自举的下载阶段。
if out=$(PROBE_VERBOSE=1 http_proxy=http://p.example:1 https_proxy=http://p.example:1 \
        /bin/bash "$ROOT/run_bootstrap_probe.sh" "$HERE/.." "$ROOT/stub-src" 2>&1) \
        && printf '%s' "$out" | grep -q 'env http_proxy=http://p.example:1 https_proxy=http://p.example:1' \
        && printf '%s' "$out" | grep -q 'PROBE-OK'; then
    pass "proxy variables are passed through sudo"
else
    failed "proxy variables did not reach the bootstrap command: $out"
fi

# ---- 试运行不许碰网络 -----------------------------------------------------
#
# 两个真实故障都出在这一段：
#   1. 探测种子时连不上，跑完三轮超时重试，屏幕上两分钟没有一行字，用户以为
#      卡死，按 Ctrl-C 走了。
#   2. `--dry-run --from-source` 会真的下载源码并跑 bootstrap —— 说好只是
#      预演，却动了东西。
# 所以这里放一个只记账的假 curl：试运行时它一次都不该被调用。

mkdir -p "$ROOT/fakebin"
cat > "$ROOT/fakebin/curl" <<'FAKECURL'
#!/bin/sh
printf 'curl-called %s\n' "$*" >> "$FAKE_CURL_LOG"
exit 7
FAKECURL
chmod 755 "$ROOT/fakebin/curl"

export FAKE_CURL_LOG=$ROOT/curl.log
rm -f "$FAKE_CURL_LOG"
dry_out=$(PATH=$ROOT/fakebin:$PATH FINX_TEST=$ROOT/dry /bin/bash "$INSTALL" --dry-run 2>&1)
dry_rc=$?

if [ "$dry_rc" -eq 0 ] && [ ! -s "$FAKE_CURL_LOG" ]; then
    pass "--dry-run does not touch the network"
else
    failed "--dry-run reached the network or failed (rc=$dry_rc)"
fi

if printf '%s' "$dry_out" | grep -q 'If a seed answers' \
        && printf '%s' "$dry_out" | grep -q 'Otherwise: building from source' \
        && printf '%s' "$dry_out" | grep -q 'releases/download/seed-'; then
    pass "--dry-run lists the addresses it would ask and both outcomes"
else
    failed "--dry-run did not print both branch plans: $dry_out"
fi

rm -f "$FAKE_CURL_LOG"
PATH=$ROOT/fakebin:$PATH FINX_TEST=$ROOT/dry-src /bin/bash "$INSTALL" --dry-run --from-source \
    >/dev/null 2>&1
src_rc=$?
if [ "$src_rc" -eq 0 ] && [ ! -s "$FAKE_CURL_LOG" ]; then
    pass "--dry-run --from-source does not download anything"
else
    failed "--dry-run --from-source reached the network or failed (rc=$src_rc)"
fi

# 第三个故障：extract_seed 曾经先查文件、后看 dry_run。试运行既不下载也不
# 拷本地种子，那个文件根本不存在 —— 于是整条最该能离线走的 --seed-dir 预演
# 走到「解包」就报错退出。
if FINX_TEST=$ROOT /bin/bash "$INSTALL" --dry-run --seed-dir="$ROOT" \
        --prefix="$ROOT/dry-seed" >"$ROOT/dry-seed.log" 2>&1 \
        && grep -q 'nothing was changed' "$ROOT/dry-seed.log"; then
    pass "--dry-run --seed-dir walks the whole plan"
else
    failed "--dry-run --seed-dir did not finish: $(tail -3 "$ROOT/dry-seed.log" 2>/dev/null)"
fi

# ---- 汇总 ---------------------------------------------------------------

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS: all checks green (sandbox %s)\n' "$ROOT"
    exit 0
fi
printf 'FAIL: %d check(s) failed (sandbox %s)\n' "$failures" "$ROOT"
exit 1
