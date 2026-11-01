#!/bin/bash
#
# finx-install/install.sh - 从零安装 Finx（模块化入口）
#
# 注意：这不是 fink 包的安装阶段脚本。那个是仓库根的 install.sh，
# 由 fink.info.in 的 InstallScript 调用。区别见 docs/TECHNICAL-GUIDE.md 8.6。
#
# 两种调用方式：
#
#   目录模式   ./finx-install/install.sh [选项]
#   单文件     /bin/bash -c "$(curl -fsSL <standalone.sh 的地址>)" -- [选项]
#
# 单文件由 finx-install/build-bundle.sh 从本文件与 lib/*.sh 生成。
#
# 选项：
#   --prefix=DIR        安装到 DIR（默认 /opt/finx）
#   --seed-dir=DIR      用本地目录里的 manifest 与种子，全程不联网
#   --manifest-url=URL  清单的绝对地址
#   --arch=ARCH         覆盖探测到的架构（arm64 / x86_64）
#   --dry-run           只打印将要做什么，不改动任何文件
#   --force             允许覆盖已存在的安装
#   -h, --help          显示帮助

set -u
set -o pipefail

# >>> bundle:skip
# 目录模式下加载 lib/*.sh。build-bundle.sh 会把本段整段丢弃并把 lib 内容内联 ——
# 被 bash 管道执行时既没有可靠的 $0，也没有同级目录可用。
if [ "${FINX_BUNDLED:-0}" -ne 1 ]; then
    FINX_INSTALL_DIR=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || FINX_INSTALL_DIR=""
    for needed in common detect manifest extract; do
        if [ ! -f "$FINX_INSTALL_DIR/lib/$needed.sh" ]; then
            printf 'ERROR: lib/%s.sh not found next to %s\n' "$needed" "${0:-<stdin>}" >&2
            printf '       This modular entry point needs its lib/ directory.\n' >&2
            printf '       To run it from a pipe, use the generated single file:\n' >&2
            printf '         /bin/bash -c "$(curl -fsSL <standalone.sh>)"\n' >&2
            exit 1
        fi
    done
    . "$FINX_INSTALL_DIR/lib/common.sh"
    . "$FINX_INSTALL_DIR/lib/detect.sh"
    . "$FINX_INSTALL_DIR/lib/manifest.sh"
    . "$FINX_INSTALL_DIR/lib/extract.sh"
fi
# <<< bundle:skip

# >>> bundle:body
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
    info "Package operations run as root, like MacPorts; fink asks for sudo itself."
}

main "$@"
