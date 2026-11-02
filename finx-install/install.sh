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
# finx-install/install.sh - 从零安装 Finx（模块化入口）
#
# 注意：这不是 finx 包的安装阶段脚本。那个是仓库根的 install.sh，
# 由 finx.info.in 的 InstallScript 调用。区别见 docs/TECHNICAL-GUIDE.md 8.6。
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
#   --from-source       直接走源码自举，不先试种子
#   --source-url=URL    源码归档地址（默认 codeload 上的 tar.gz）
#   --ref=REF           源码归档的分支或提交（默认 main）
#   --no-fallback       种子取不到就失败，不退回源码
#   --force             允许覆盖已存在的安装
#   -h, --help          显示帮助

set -u
set -o pipefail

# >>> bundle:skip
# 目录模式下加载 lib/*.sh。build-bundle.sh 会把本段整段丢弃并把 lib 内容内联 ——
# 被 bash 管道执行时既没有可靠的 $0，也没有同级目录可用。
if [ "${FINX_BUNDLED:-0}" -ne 1 ]; then
    FINX_INSTALL_DIR=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || FINX_INSTALL_DIR=""
    for needed in common detect manifest extract source; do
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
    . "$FINX_INSTALL_DIR/lib/source.sh"
fi
# <<< bundle:skip

# >>> bundle:body
PREFIX=/opt/finx
PREFIX_EXPLICIT=0
NO_PATH=0
SEED_DIR=""
MANIFEST_URL=${FINX_MANIFEST_URL:-}
ARCH_OVERRIDE=""
FORCE=0

# 安装方式：seed 走预编译快照，source 走源码自举。resolve_method 决定用哪个。
MODE=""
FROM_SOURCE=0
ALLOW_FALLBACK=1
SOURCE_URL=""
SOURCE_REF=${FINX_SOURCE_REF:-main}
IN_TEST_ROOT=0
INSTALLED_RELEASE=""

usage() {
    cat <<'USAGE'
Usage: install.sh [options]

  --prefix=DIR        install into DIR (default /opt/finx)
  --seed-dir=DIR      use a local manifest and seed; no network access
  --manifest-url=URL  absolute URL of the seed manifest
  --arch=ARCH         override the detected architecture (arm64 / x86_64)
  --from-source       skip the seed and build from source
  --source-url=URL    source archive to build (default: codeload tar.gz)
  --ref=REF           branch or commit for the default source archive (default: main)
  --no-fallback       fail when no seed is reachable instead of building from source
  --no-path           leave your shell startup file alone
  --force             replace an existing installation
  -h, --help          show this help

Environment:
  FINX_INDEX_DOMAIN   base URL for the seed manifest (default https://finx.sh/finx/seed)
  FINX_SEED_DOMAIN    base URL for the seed tarball when the manifest lists no url
  FINX_SOURCE_DOMAIN  base URL for the source archive when building from source
                      (default https://codeload.github.com/Fincote/Finx)
  FINX_SOURCE_REF     branch, tag or commit to pull when building from source
                      (default main); same as --ref
  FINX_CONNECT_TIMEOUT
                      seconds to wait for a connection before trying the next
                      candidate (default 30). Applies to connecting only, not to
                      how long a download may take.
  FINX_TEST=DIR       confine the whole run to DIR: the default prefix becomes
                      DIR/opt/finx, temporary files go to DIR/tmp, and --prefix
                      outside DIR is refused. Meant for tests and CI.

  Addresses must be https:// or file://; plain http is accepted only for
  http://127.0.0.1:PORT and http://localhost:PORT (offline testing).
  Changing a domain never skips verification: seeds are still checked
  against the sha256 and size in the manifest.

Examples:
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
            --from-source)    FROM_SOURCE=1 ;;
            --source-url=*)   SOURCE_URL=${1#*=} ;;
            --source-url)     shift; [ $# -gt 0 ] || die "--source-url needs a value"; SOURCE_URL=$1 ;;
            --ref=*)          SOURCE_REF=${1#*=} ;;
            --ref)            shift; [ $# -gt 0 ] || die "--ref needs a value"; SOURCE_REF=$1 ;;
            --no-fallback)    ALLOW_FALLBACK=0 ;;
            --no-path)        NO_PATH=1 ;;
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

# 装完之后 finx 还不在 PATH 上 —— 子进程改不了父 shell 的环境变量，
# 所以只有两条路：让用户自己 source，或写进 shell 的启动文件。
#
# 这里不自动写启动文件。这个安装器的典型用法是 `curl ... | bash`，
# 在用户没看清的情况下改 .zprofile 是坏做法，而且改错了很难发现。
# 所以：按用户的登录 shell 给出**精确到文件**的那一行，用户可以复制粘贴；
# 想让它代劳的，指向随包安装的 pathsetup.sh。
# ---------------------------------------------------------------------------
# 让 finx 在当前 shell 与今后的 shell 里都能直接用
# ---------------------------------------------------------------------------
#
# 脚本改不了父 shell 的 PATH —— 子进程影响不了父进程。所以能做的只有两件：
# 写进 shell 的启动文件（持久），以及告诉用户这一句怎么 source（当次生效）。
#
# 写启动文件有个必须小心的前提：安装器可能以 root 跑（`curl | sudo bash`），
# 那时 $HOME 是 /var/root。往 root 的 .zprofile 里加东西既没用又有害。
# 所以先解析出「真正在用的那个用户」的家目录（$SUDO_USER + Directory
# Services），写完之后再把属主改回去。

# 正在以 root 跑时，找出调用者的家目录；否则就是 $HOME。
target_home() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        # 不能写 ~/$SUDO_USER —— 那会拿到 /var/root/xxx。要问 Directory Services。
        home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        if [ -n "$home" ] && [ -d "$home" ]; then
            printf '%s\n' "$home"
            return 0
        fi
        return 1
    fi
    printf '%s\n' "$HOME"
}

login_shell_name() {
    basename "${SHELL:-/bin/zsh}"
}

# 该往哪个启动文件里写。zsh 用 .zprofile（登录 shell 会读），bash 优先
# .bash_profile（存在才是它），csh 用 .cshrc。
shell_rc_path() {
    home=$1
    case $(login_shell_name) in
        zsh)  printf '%s/.zprofile\n' "$home" ;;
        bash)
            if [ -f "$home/.bash_profile" ]; then
                printf '%s/.bash_profile\n' "$home"
            else
                printf '%s/.profile\n' "$home"
            fi ;;
        csh|tcsh) printf '%s/.cshrc\n' "$home" ;;
        *)    printf '%s/.profile\n' "$home" ;;
    esac
}

# 要写进去的那一行。带 test -r 是为了在 finx 被删掉之后不会让每个新
# shell 都报一次错。
shell_source_line() {
    case $(login_shell_name) in
        csh|tcsh) printf 'test -r %s/bin/init.csh && source %s/bin/init.csh\n' "$PREFIX" "$PREFIX" ;;
        *)        printf 'test -r %s/bin/init.sh && . %s/bin/init.sh\n' "$PREFIX" "$PREFIX" ;;
    esac
}

# 只打印，不写。写失败、或用户明确不要时用。
print_path_help() {
    printf '\n'
    printf 'To use finx in this shell now:\n'
    printf '    . %s/bin/init.sh\n' "$PREFIX"
    printf '\n'
    printf 'To make it permanent, add this line to your shell startup file:\n'
    printf '    %s\n' "$(shell_source_line)"
    printf '\n'
    printf 'Or re-run this installer without --no-path to have it done for you.\n'
    printf '\n'
    printf 'Note: finx uses its own prefix, so it never shadows a Fink\n'
    printf 'installation that may already be present under /sw.\n'
}

# 默认就写。--no-path 关掉。
setup_path() {
    if [ "$NO_PATH" -eq 1 ]; then
        info "leaving your shell configuration alone (--no-path)"
        print_path_help
        return 0
    fi

    home=$(target_home) || {
        warn "cannot determine the invoking user's home directory"
        print_path_help
        return 0
    }

    rc=$(shell_rc_path "$home")
    line=$(shell_source_line)

    # 幂等：已经有了就别重复追加。
    if grep -qxF "$line" "$rc" 2>/dev/null; then
        info "PATH setup already present in $rc"
    elif printf '\n# Finx: put finx on PATH\n%s\n' "$line" >> "$rc" 2>/dev/null; then
        info "added finx to PATH in $rc"
        # 以 root 写进别人的文件后要把属主还回去，否则那个用户今后改不了它。
        if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            chown "$SUDO_USER" "$rc" 2>/dev/null \
                || warn "could not chown $rc back to $SUDO_USER"
        fi
    else
        warn "could not write $rc"
        print_path_help
        return 0
    fi

    printf '\n'
    printf 'finx is now on PATH for new shells. For this one, run:\n'
    printf '    . %s/bin/init.sh\n' "$PREFIX"
}

main() {
    parse_args "$@"
    apply_test_root

    step "Checking host"
    detect_host
    [ -n "$ARCH_OVERRIDE" ] && HOST_ARCH=$ARCH_OVERRIDE
    info "macOS $HOST_MACOS_MAJOR, arch $HOST_ARCH, prefix $PREFIX"
    require curl

    step "Choosing install method"
    resolve_method

    case $MODE in
        seed)   install_from_seed ;;
        source) install_from_source ;;
    esac

    printf '\n'
    info "Finx ${INSTALLED_RELEASE:-unknown} installed in $PREFIX"
    setup_path
    info "Package operations run as root, like MacPorts; finx asks for sudo itself."
}

# 种子优先，取不到再退回源码。显式给了 --seed-dir / --manifest-url 时不回落，
# 因为那说明调用方指定了来源，静默换源会让校验失去意义。
resolve_method() {
    if [ -n "$SEED_DIR" ] || [ -n "$MANIFEST_URL" ]; then
        MODE=seed
        info "seed, from an explicit location"
        return 0
    fi

    if [ "$FROM_SOURCE" -eq 1 ]; then
        MODE=source
        info "source, because --from-source was given"
        return 0
    fi

    if [ "$ALLOW_FALLBACK" -eq 0 ]; then
        MODE=seed
        info "seed, from the default manifest"
        return 0
    fi

    MANIFEST_URL=$DEFAULT_MANIFEST_URL
    if probe_url "$MANIFEST_URL"; then
        MODE=seed
        info "seed, from $MANIFEST_URL"
    else
        MODE=source
        warn "no seed manifest at $MANIFEST_URL yet; falling back to a source build"
        warn "that path needs the Xcode Command Line Tools and compiles tar and dpkg"
    fi
}

install_from_seed() {
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

    INSTALLED_RELEASE=${SEED_RELEASE:-unknown}
}

install_from_source() {
    step "Checking target"
    check_target
    require_write_access "$PREFIX"

    step "Obtaining the source tree"
    fetch_source

    # bootstrap 自己会创建前缀并写配置、建索引，这里不再重复一遍
    step "Bootstrapping"
    run_bootstrap "$PREFIX"

    INSTALLED_RELEASE=$(cat "$SOURCE_ROOT/VERSION" 2>/dev/null || echo unknown)
}

main "$@"
