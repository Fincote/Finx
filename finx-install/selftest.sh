#!/bin/bash
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
mkdir -p "$SEED/bin" "$SEED/lib/fink" "$SEED/etc" || exit 1

cat > "$SEED/bin/fink" <<'STUB'
#!/bin/sh
case "$1" in
    scanpackages) echo "stub: fink scanpackages"; exit 0 ;;
    *) echo "stub fink $*"; exit 0 ;;
esac
STUB
chmod 755 "$SEED/bin/fink"
printf 'Debian dpkg version 1.19.7 (stub)\n' > "$SEED/bin/dpkg-stub"
chmod 755 "$SEED/bin/dpkg-stub"
echo "0.46.0" > "$SEED/lib/fink/version"
printf 'placeholder\n' > "$SEED/etc/seed.txt"

tar -czf "$ROOT/seed.tar.gz" -C "$SEED" . || exit 1
SEED_SIZE=$(wc -c < "$ROOT/seed.tar.gz" | tr -d ' ')
SEED_SHA=$(shasum -a 256 "$ROOT/seed.tar.gz" | awk '{print $1}')
HOST_ARCH=$(uname -m)

write_manifest() {
    printf 'schema 1\nrelease 0.46.0\narch %s\nseed seed.tar.gz\nsize %s\nsha256 %s\n' \
        "$HOST_ARCH" "$SEED_SIZE" "$SEED_SHA" > "$1"
}

write_manifest "$ROOT/manifest"

printf '== selftest: FINX_TEST=%s\n\n' "$ROOT"

# ---- 1. dry-run 不得创建前缀 --------------------------------------------

"$INSTALL" --seed-dir="$ROOT" --dry-run >/dev/null 2>&1 \
    || failed "dry-run exits non-zero"
[ ! -e "$ROOT/opt/finx" ] && pass "dry-run created nothing" || failed "dry-run created $ROOT/opt/finx"

# ---- 2. 默认前缀落在测试根内 --------------------------------------------

if "$INSTALL" --seed-dir="$ROOT" >/dev/null 2>&1; then
    pass "install with default prefix"
else
    failed "install with default prefix"
fi

if [ -f "$ROOT/opt/finx/bin/fink" ]; then
    pass "seed extracted into the test root"
else
    failed "seed not extracted into the test root"
fi

if grep -qx "Basepath: $ROOT/opt/finx" "$ROOT/opt/finx/etc/fink.conf" 2>/dev/null; then
    pass "fink.conf records the sandbox prefix"
else
    failed "fink.conf does not record the sandbox prefix"
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

if cat "$HERE/standalone.sh" | /bin/bash -s -- --seed-dir="$ROOT" --prefix="$ROOT/piped" >/dev/null 2>&1; then
    pass "piped standalone install"
else
    failed "piped standalone install"
fi
[ -f "$ROOT/piped/bin/fink" ] && pass "piped install landed in the sandbox" \
    || failed "piped install did not land in the sandbox"

# ---- 7. 单文件必须与源同步 ----------------------------------------------

check_ok "standalone.sh is not stale" "$HERE/build-bundle.sh" --check

# ---- 汇总 ---------------------------------------------------------------

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS: all checks green (sandbox %s)\n' "$ROOT"
    exit 0
fi
printf 'FAIL: %d check(s) failed (sandbox %s)\n' "$failures" "$ROOT"
exit 1
