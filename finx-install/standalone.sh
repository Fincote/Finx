#!/bin/bash
#
# finx-install/standalone.sh - 从零安装 Finx
#
# 本文件由 finx-install/build-bundle.sh 生成，请勿直接编辑。
# 唯一事实来源：finx-install/install.sh 与 finx-install/lib/*.sh
#
# 用法：/bin/bash -c "$(curl -fsSL <本文件的地址>)" -- [选项]
#

FINX_BUNDLED=1
set -u
set -o pipefail

# ======== lib/common.sh ========
# shellcheck shell=bash
#
# 通用工具：输出、错误、临时目录、命令探测、校验和。
# 由 install.sh 以 . 方式加载，不单独执行。
#
# 约定：面向用户的文案一律英文，注释用中文。

FINX_TMP=""

cleanup() {
    if [ -n "$FINX_TMP" ] && [ -d "$FINX_TMP" ]; then
        rm -rf "$FINX_TMP"
    fi
    FINX_TMP=""
}

on_exit() {
    rc=$?
    cleanup
    exit $rc
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step() {
    printf '\n==> %s\n' "$*"
}

info() {
    printf '    %s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require() {
    have "$1" || die "required command not found: $1"
}

# 所有会改动文件系统的动作都经过 run()，这样 --dry-run 只需要一处判断。
run() {
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would run: $*"
        return 0
    fi
    "$@"
}

ensure_tmp() {
    if [ -z "$FINX_TMP" ]; then
        FINX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/finx-install.XXXXXX") \
            || die "cannot create a temporary directory"
    fi
}

sha256_of() {
    if have shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif have openssl; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        die "no sha256 tool available (need shasum or openssl)"
    fi
}

file_size() {
    wc -c < "$1" | tr -d ' '
}

human_size() {
    awk -v n="$1" 'BEGIN {
        split("B KB MB GB TB", unit, " ")
        i = 1
        while (n >= 1024 && i < 5) { n /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), n, unit[i]
    }'
}

lower() {
    printf '%s' "$1" | tr 'A-Z' 'a-z'
}

# ---- 测试根 ---------------------------------------------------------------
#
# FINX_TEST=<绝对路径> 把整个安装器关进这个目录：
#
#   * 默认前缀变成 <测试根>/opt/finx
#   * 临时文件落在 <测试根>/tmp（TMPDIR 一并改掉）
#   * --prefix 只允许指向测试根内部，越界即中止
#
# 相对路径、/、以及解析后落在系统目录里的路径一律拒绝 —— 宁可不跑，
# 也不要因为一个环境变量写错就去动真实安装。

# 规范化路径：存在就 pwd -P，不存在就把最深的已存在祖先规范化后接回剩余部分。
# macOS 上 /tmp 是指向 /private/tmp 的符号链接，不这么做比对会假阴性。
resolve_path() {
    target=$1
    current=$target
    tail=""

    while [ ! -d "$current" ] && [ "$current" != "/" ]; do
        tail="/$(basename -- "$current")$tail"
        current=$(dirname -- "$current")
    done

    if [ -d "$current" ]; then
        (cd -- "$current" && printf '%s%s\n' "$(pwd -P)" "$tail")
    else
        printf '%s\n' "$target"
    fi
}

apply_test_root() {
    [ -n "${FINX_TEST:-}" ] || return 0

    case $FINX_TEST in
        /*) ;;
        *) die "FINX_TEST must be an absolute path (got: $FINX_TEST)" ;;
    esac

    mkdir -p "$FINX_TEST" 2>/dev/null || die "cannot create FINX_TEST=$FINX_TEST"
    TEST_ROOT=$(cd -- "$FINX_TEST" && pwd -P) || die "cannot resolve FINX_TEST=$FINX_TEST"

    [ "$TEST_ROOT" != "/" ] || die "FINX_TEST must not resolve to /"

    case $TEST_ROOT in
        /System|/System/*|/usr|/usr/*|/Library|/Library/*|/Applications|/Applications/*|/bin|/bin/*|/sbin|/sbin/*)
            die "FINX_TEST must not point into a system directory: $TEST_ROOT" ;;
    esac

    mkdir -p "$TEST_ROOT/tmp" || die "cannot create $TEST_ROOT/tmp"
    TMPDIR=$TEST_ROOT/tmp
    export TMPDIR

    if [ "${PREFIX_EXPLICIT:-0}" -eq 1 ]; then
        prefix_real=$(resolve_path "$PREFIX")
        case $prefix_real in
            "$TEST_ROOT"/*) ;;
            *) die "--prefix must live under FINX_TEST ($TEST_ROOT), got $prefix_real" ;;
        esac
    else
        PREFIX=$TEST_ROOT/opt/finx
    fi

    info "test root: $TEST_ROOT (nothing outside it will be touched)"
}

# ======== lib/detect.sh ========
# shellcheck shell=bash
#
# 宿主与目标目录的探测。由 install.sh 以 . 方式加载，不单独执行。

# 设置 HOST_MACOS_VERSION / HOST_MACOS_MAJOR / HOST_ARCH。
detect_host() {
    require sw_vers
    require uname

    HOST_MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null) \
        || die "cannot read the macOS version (sw_vers failed)"
    HOST_MACOS_MAJOR=${HOST_MACOS_VERSION%%.*}

    case $HOST_MACOS_MAJOR in
        ''|*[!0-9]*) die "cannot parse the macOS version: $HOST_MACOS_VERSION" ;;
    esac

    HOST_ARCH=$(uname -m)
    case $HOST_ARCH in
        arm64|x86_64) ;;
        *) die "unsupported architecture: $HOST_ARCH" ;;
    esac

    if [ "$HOST_MACOS_MAJOR" -lt 14 ]; then
        warn "macOS $HOST_MACOS_VERSION is below the supported floor (14); continuing anyway"
    fi
}

# absent | empty | existing | nonempty
target_state() {
    target=$1
    if [ ! -e "$target" ]; then
        printf 'absent\n'
    elif [ ! -d "$target" ]; then
        printf 'nonempty\n'
    elif [ -e "$target/bin/fink" ]; then
        printf 'existing\n'
    elif [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        printf 'nonempty\n'
    else
        printf 'empty\n'
    fi
}

nearest_existing_parent() {
    p=$1
    while [ ! -d "$p" ] && [ "$p" != "/" ]; do
        p=$(dirname -- "$p")
    done
    printf '%s\n' "$p"
}

require_write_access() {
    target=$1
    if [ -e "$target" ]; then
        probe=$target
    else
        probe=$(nearest_existing_parent "$target")
    fi
    if [ ! -w "$probe" ] && [ "$(id -u)" -ne 0 ]; then
        die "no write access to $probe; re-run with sudo"
    fi
}

do_mkdir() {
    run mkdir -p -m 755 "$1"
}

# ======== lib/manifest.sh ========
# shellcheck shell=bash
#
# 种子清单的解析、下载与校验。
#
# 清单是行取向的纯文本，故意不用 JSON：安装阶段不该依赖 jq，
# 而 awk 一行就能取到字段，签名与 diff 也都更方便。
#
#   schema  1
#   release 0.46.0
#   arch    arm64
#   seed    seed.tar.gz
#   size    12345678
#   sha256  <64 位十六进制>
#   url     https://host/a/seed.tar.gz
#   url     https://host/b/seed.tar.gz

# 解析清单，设置 MANIFEST_FILE / ARTIFACT_BASE / ARTIFACT_FILE /
# SEED_NAME / SEED_SIZE / SEED_SHA256 / SEED_RELEASE。
resolve_manifest() {
    ensure_tmp

    if [ -n "$SEED_DIR" ]; then
        [ -d "$SEED_DIR" ] || die "seed directory not found: $SEED_DIR"
        MANIFEST_FILE=$SEED_DIR/manifest
        ARTIFACT_BASE=$SEED_DIR
    else
        [ -n "$MANIFEST_URL" ] || die "no seed location given; use --seed-dir or --manifest-url"
        MANIFEST_FILE=$FINX_TMP/manifest
        ARTIFACT_BASE=""
        fetch_one "$MANIFEST_URL" "$MANIFEST_FILE" \
            || die "cannot download the seed manifest from $MANIFEST_URL"
    fi

    [ -f "$MANIFEST_FILE" ] || die "manifest not found: $MANIFEST_FILE"

    schema=$(manifest_field "$MANIFEST_FILE" schema)
    [ "$schema" = "1" ] || die "unsupported manifest schema: ${schema:-<missing>}"

    manifest_arch=$(manifest_field "$MANIFEST_FILE" arch)
    [ "$manifest_arch" = "$HOST_ARCH" ] \
        || die "seed is built for $manifest_arch but this host is $HOST_ARCH"

    SEED_RELEASE=$(manifest_field "$MANIFEST_FILE" release)
    SEED_NAME=$(manifest_field "$MANIFEST_FILE" seed)
    SEED_SIZE=$(manifest_field "$MANIFEST_FILE" size)
    SEED_SHA256=$(manifest_field "$MANIFEST_FILE" sha256)

    [ -n "$SEED_NAME" ] || die "manifest has no seed entry"
    case $SEED_NAME in
        */*) die "manifest seed name must not contain a path separator" ;;
    esac
    [ -n "$SEED_SHA256" ] || die "manifest has no sha256 entry"
    case $SEED_SIZE in
        ''|*[!0-9]*) die "manifest size must be a byte count" ;;
    esac

    ARTIFACT_FILE=$FINX_TMP/$SEED_NAME
    info "seed $SEED_NAME (release ${SEED_RELEASE:-unknown}, $(human_size "$SEED_SIZE"))"
}

manifest_field() {
    awk -v key="$2" '$1 == key { print $2; exit }' "$1"
}

manifest_urls() {
    awk '$1 == "url" { print $2 }' "$1"
}

# 下载单个 URL 到目标路径。先写 .part，成功后再改名，因此 -C - 续传是安全的。
fetch_one() {
    url=$1
    dest=$2

    info "GET $url"
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would download to $dest"
        return 0
    fi

    part=$dest.part
    if ! curl -fL --connect-timeout 30 --retry 2 -C - -o "$part" "$url"; then
        # 退出码 33 是「服务器不支持续传」，此时从头再来一次
        rm -f "$part"
        curl -fL --connect-timeout 30 -o "$part" "$url" || {
            rm -f "$part"
            return 1
        }
    fi
    mv -f "$part" "$dest" || return 1
    return 0
}

# 取得种子产物：本地目录直接拷贝，否则按清单里的 url 逐个尝试。
fetch_artifact() {
    if [ -n "$ARTIFACT_BASE" ]; then
        src=$ARTIFACT_BASE/$SEED_NAME
        [ -f "$src" ] || die "seed artifact not found: $src"
        info "using local artifact $src"
        run cp -f "$src" "$ARTIFACT_FILE"
        return 0
    fi

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would download $SEED_NAME from the manifest urls"
        return 0
    fi

    manifest_urls "$MANIFEST_FILE" > "$FINX_TMP/urls"
    [ -s "$FINX_TMP/urls" ] || die "manifest has no url entries"

    tried=0
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        tried=$((tried + 1))
        if fetch_one "$url" "$ARTIFACT_FILE"; then
            return 0
        fi
        warn "mirror failed: $url"
    done < "$FINX_TMP/urls"

    die "all $tried mirror(s) failed for $SEED_NAME"
}

# 体积与 SHA256 都核对；任何一项不符都中止，不做「警告后继续」。
verify_file() {
    file=$1
    want_sha=$2
    want_size=$3

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would verify size and sha256 of $file"
        return 0
    fi

    [ -f "$file" ] || die "artifact missing: $file"

    got_size=$(file_size "$file")
    [ "$got_size" = "$want_size" ] \
        || die "size mismatch for $SEED_NAME: expected $want_size bytes, got $got_size"

    got_sha=$(sha256_of "$file")
    if [ "$(lower "$got_sha")" != "$(lower "$want_sha")" ]; then
        die "sha256 mismatch for $SEED_NAME: expected $want_sha, got $got_sha"
    fi
    info "sha256 ok"
}

# ======== lib/extract.sh ========
# shellcheck shell=bash
#
# 落盘与收尾：解包、修权限、ad-hoc 重签名、写配置、重建索引。
# 由 install.sh 以 . 方式加载，不单独执行。

extract_seed() {
    archive=$1
    target=$2

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would extract $archive into $target"
        return 0
    fi

    [ -f "$archive" ] || die "seed archive missing: $archive"
    [ -d "$target" ] || die "target directory missing: $target"

    tar -xzf "$archive" -C "$target" || die "failed to extract $archive"
}

# 种子里的文件在打包时已是 root 所有；以非 root 安装时只修目录权限即可。
fix_permissions() {
    target=$1

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would normalize ownership and modes under $target"
        return 0
    fi

    if [ "$(id -u)" -eq 0 ]; then
        for sub in bin sbin lib etc var/lib/dpkg; do
            [ -e "$target/$sub" ] && chown -R root:wheel "$target/$sub" 2>/dev/null
        done
    fi

    for dir in "$target" "$target/bin" "$target/sbin" "$target/lib" "$target/etc"; do
        [ -d "$dir" ] && chmod 755 "$dir"
    done
    return 0
}

is_macho() {
    magic=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case $magic in
        cffaedfe|cefaedfe|cafebabe|bebafeca) return 0 ;;
        *) return 1 ;;
    esac
}

# 改动过二进制的种子必须重签名：Apple 芯片拒跑签名失效的可执行文件。
resign_macho() {
    target=$1

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would ad-hoc re-sign Mach-O files under $target"
        return 0
    fi

    if ! have codesign; then
        warn "codesign not found; skipping ad-hoc re-signing"
        return 0
    fi

    signed=0
    for file in "$target"/bin/* "$target"/sbin/* "$target"/lib/*.dylib; do
        [ -f "$file" ] || continue
        is_macho "$file" || continue
        if codesign -f -s - "$file" >/dev/null 2>&1; then
            signed=$((signed + 1))
        fi
    done
    info "re-signed $signed Mach-O file(s)"
}

# 只在配置不存在时写：已装过的目录里那份可能有用户调整。
write_config() {
    target=$1
    conf=$target/etc/fink.conf

    if [ -e "$conf" ]; then
        info "keeping existing $conf"
        return 0
    fi

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would write $conf"
        return 0
    fi

    mkdir -p "$target/etc" || die "cannot create $target/etc"
    cat > "$conf" <<EOF
# Finx configuration, created by finx-install
# 其余字段（Trees / Distribution / SelfUpdateTrees）由 fink configure 补全。
Basepath: $target
EOF
}

run_scanpackages() {
    target=$1

    if [ ! -x "$target/bin/fink" ]; then
        warn "this seed has no $target/bin/fink; skipping the package index rebuild"
        return 0
    fi

    run "$target/bin/fink" scanpackages || warn "fink scanpackages failed; run it manually later"
    return 0
}

# ======== install.sh ========
PREFIX=/opt/finx
PREFIX_EXPLICIT=0
SEED_DIR=""
MANIFEST_URL=${FINX_MANIFEST_URL:-}
ARCH_OVERRIDE=""
DRY_RUN=0
FORCE=0

usage() {
    cat <<'USAGE'
Usage: install.sh [options]

  --prefix=DIR        install into DIR (default /opt/finx)
  --seed-dir=DIR      use a local manifest and seed; no network access
  --manifest-url=URL  absolute URL of the seed manifest
  --arch=ARCH         override the detected architecture (arm64 / x86_64)
  --dry-run           print what would happen, change nothing
  --force             replace an existing installation
  -h, --help          show this help

Environment:
  FINX_TEST=DIR       confine the whole run to DIR: the default prefix becomes
                      DIR/opt/finx, temporary files go to DIR/tmp, and --prefix
                      outside DIR is refused. Meant for tests and CI.

Examples:
  ./finx-install/install.sh --dry-run
  FINX_TEST=/tmp/finx-check ./finx-install/install.sh --seed-dir=/tmp/seed
  /bin/bash -c "$(curl -fsSL <standalone.sh>)" -- --prefix=/opt/finx
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --prefix=*)       PREFIX=${1#*=}; PREFIX_EXPLICIT=1 ;;
            --prefix)         shift; [ $# -gt 0 ] || die "--prefix needs a value"; PREFIX=$1; PREFIX_EXPLICIT=1 ;;
            --seed-dir=*)     SEED_DIR=${1#*=} ;;
            --seed-dir)       shift; [ $# -gt 0 ] || die "--seed-dir needs a value"; SEED_DIR=$1 ;;
            --manifest-url=*) MANIFEST_URL=${1#*=} ;;
            --manifest-url)   shift; [ $# -gt 0 ] || die "--manifest-url needs a value"; MANIFEST_URL=$1 ;;
            --arch=*)         ARCH_OVERRIDE=${1#*=} ;;
            --arch)           shift; [ $# -gt 0 ] || die "--arch needs a value"; ARCH_OVERRIDE=$1 ;;
            --dry-run)        DRY_RUN=1 ;;
            --force)          FORCE=1 ;;
            -h|--help)        usage; exit 0 ;;
            --)               shift; break ;;
            *)                die "unknown option: $1" ;;
        esac
        shift
    done

    case $PREFIX in
        /*) ;;
        *) die "--prefix must be an absolute path" ;;
    esac
    case $PREFIX in
        */) die "--prefix must not end with a slash" ;;
    esac
}

check_target() {
    state=$(target_state "$PREFIX")
    case $state in
        absent) ;;
        empty)
            warn "$PREFIX exists and is empty; continuing" ;;
        existing)
            [ "$FORCE" -eq 1 ] || die "$PREFIX already holds an installation; re-run with --force to replace it"
            warn "replacing the existing installation in $PREFIX" ;;
        *)
            [ "$FORCE" -eq 1 ] || die "$PREFIX is not empty and does not look like a Finx installation"
            warn "$PREFIX is not a Finx installation; continuing because --force was given" ;;
    esac
}

main() {
    parse_args "$@"
    apply_test_root

    step "Checking host"
    detect_host
    [ -n "$ARCH_OVERRIDE" ] && HOST_ARCH=$ARCH_OVERRIDE
    info "macOS $HOST_MACOS_MAJOR, arch $HOST_ARCH, prefix $PREFIX"
    require curl

    step "Resolving seed manifest"
    resolve_manifest

    step "Checking target"
    check_target
    require_write_access "$PREFIX"

    step "Obtaining $SEED_NAME"
    fetch_artifact

    # 先校验再动目标目录：失败时不该留下一个空壳
    step "Verifying"
    verify_file "$ARTIFACT_FILE" "$SEED_SHA256" "$SEED_SIZE"

    step "Preparing $PREFIX"
    do_mkdir "$PREFIX"

    step "Extracting"
    extract_seed "$ARTIFACT_FILE" "$PREFIX"

    step "Finalizing"
    fix_permissions "$PREFIX"
    resign_macho "$PREFIX"
    write_config "$PREFIX"
    run_scanpackages "$PREFIX"

    printf '\n'
    info "Finx ${SEED_RELEASE:-unknown} installed in $PREFIX"
    info "Add it to this shell with: . $PREFIX/bin/init.sh"
}

main "$@"
