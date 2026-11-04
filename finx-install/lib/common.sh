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

# ---------------------------------------------------------------------------
# 屏幕输出：颜色与横幅
# ---------------------------------------------------------------------------
#
# 用 echo -e：脚本的 shebang 是 bash（见 62529dd5 统一过），bash 内建的 echo
# 认 -e。项目约定如此，横幅内容也不含需要转义的东西。

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BOLD_BLUE='\033[1;38;5;25m'
BOLD='\033[1m'
RESET='\033[0m'

print_banner() {
    echo ""
    echo -e "${GREEN}███████╗██╗███╗   ██╗██╗  ██╗${RESET}"
    echo -e "${GREEN}██╔════╝██║████╗  ██║╚██╗██╔╝${RESET}"
    echo -e "${GREEN}█████╗  ██║██╔██╗ ██║ ╚███╔╝ ${RESET}"
    echo -e "${GREEN}██╔══╝  ██║██║╚██╗██║ ██╔██╗ ${RESET}"
    echo -e "${GREEN}██║     ██║██║ ╚████║██╔╝ ██╗${RESET}"
    echo -e "${GREEN}╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝${RESET}"
    echo ""
    echo -e "${GREEN}$(t 'Welcome to FINX!' '欢迎使用 FINX！')${RESET}"
    echo ""
}

# ---------------------------------------------------------------------------
# 下载源：全部由环境变量控制
# ---------------------------------------------------------------------------
#
# 与 MacWave 的 MACWAVE_*_DOMAIN 同一套做法：每个域名一个环境变量，不设就用
# 官方默认值。这样镜像、自建 CDN、本机目录都能切，而校验逻辑一条不跳。
#
# 三条约束（照搬 MacWave 的理由）：
#
#   1. 只接受 https:// 或 file://。明文 http 只放行 127.0.0.1 与 localhost
#      的带端口地址 —— 那是离线测试与本机代理用的，不是给人随便填的。
#   2. 末尾斜杠统一去掉，否则 "$DOMAIN/manifest" 会拼出双斜杠，
#      而某些服务端会因此回 404。
#   3. 报错里带上变量名。用户改了三个变量中的一个却填错时，光说
#      "invalid URL" 帮不上忙。
#
# 刻意不做的事：**换地址不等于跳过校验**。种子仍然按清单里的 sha256 与
# size 校验，源归档仍然走同一套流程。镜像只是"从哪儿拿"，不是"信不信"。
finx_domain() {
    # finx_domain <变量名> <值>：规范化并校验，成功则打印
    _finx_name=$1
    _finx_value=$2

    while [ "${_finx_value%/}" != "$_finx_value" ]; do
        _finx_value=${_finx_value%/}
    done

    case $_finx_value in
        https://?*|file://?*)  printf '%s\n' "$_finx_value"; return 0 ;;
        http://127.0.0.1:?*|http://localhost:?*) printf '%s\n' "$_finx_value"; return 0 ;;
    esac

    printf 'ERROR: %s must be an https:// (or file://) address, got: %s\n' \
        "$_finx_name" "$_finx_value" >&2
    exit 1
}

# 种子清单与种子 tar 默认同源；分开是因为可以让清单走一个域名、
# 大文件走另一个（CDN 与对象存储的常见分法）。
#
# 每个赋值后面必须跟 `|| exit 1`。finx_domain 里的 exit 1 跑在 $( ) 子 shell
# 里，只结束那个子 shell —— 父进程会继续，而变量已经被设成空串。不显式判错
# 的话，填错一个域名得到的不是报错，而是一个悄悄失效的安装器。
# 记住「用户有没有显式给过」：manifest.sh 要据此决定默认清单地址。
# 不能只看 FINX_INDEX_DOMAIN 是否非空 —— 下面这行会把它填上默认值。
FINX_INDEX_DOMAIN_GIVEN=${FINX_INDEX_DOMAIN:+1}
export FINX_INDEX_DOMAIN_GIVEN

FINX_INDEX_DOMAIN=$(finx_domain FINX_INDEX_DOMAIN "${FINX_INDEX_DOMAIN:-https://finx.sh/finx/seed}") || exit 1
export FINX_INDEX_DOMAIN

FINX_SEED_DOMAIN=$(finx_domain FINX_SEED_DOMAIN "${FINX_SEED_DOMAIN:-https://finx.sh/finx/seed}") || exit 1
export FINX_SEED_DOMAIN

# 预编译 .deb 的取处。形状是 Bottle 式的「一包一 Release」：
#   <域名>/<包名>/<包名>@<版本>-<修订>.darwin<Darwin>-<架构>.deb
# 默认指向我们自己的 debs 仓库。镜像站只要提供「域名之后那两段」的相对路径。
FINX_DEB_DOMAIN=$(finx_domain FINX_DEB_DOMAIN "${FINX_DEB_DOMAIN:-https://github.com/Fincote/debs/releases/download}") || exit 1
export FINX_DEB_DOMAIN

# 源码自举时取源码归档的地方，默认 GitHub 的 codeload。
FINX_SOURCE_DOMAIN=$(finx_domain FINX_SOURCE_DOMAIN "${FINX_SOURCE_DOMAIN:-https://codeload.github.com/Fincote/Finx}") || exit 1
export FINX_SOURCE_DOMAIN

# 连不上的等待时间。默认 30 秒；网络差的用户调小能更快地换下一个候选。
# 只管"连上"，不管"下完"——种子可能几十兆，给总时长设上限只会把慢速网络
# 的人挡在门外。
# 这里用裸 printf 而不是 die()：die 定义在后面，且本文件按顺序被 source。
case ${FINX_CONNECT_TIMEOUT:-30} in
    ''|*[!0-9]*)
        printf 'ERROR: FINX_CONNECT_TIMEOUT must be a whole number of seconds, got: %s\n' \
            "$FINX_CONNECT_TIMEOUT" >&2
        exit 1 ;;
esac
FINX_CONNECT_TIMEOUT=${FINX_CONNECT_TIMEOUT:-30}
export FINX_CONNECT_TIMEOUT

# detect_host 会填它；这里先给个空值，避免 set -u 在 detect 之前报错。
HOST_DARWIN_MAJOR=""

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step() {
    echo ""
    echo -e "${BOLD_BLUE}==>${RESET} ${BOLD}$*${RESET}"
}

# 许可协议确认。
#
# 放在**动手之前**，不是装完之后。理由：拒签时不需要回滚。
# MacWave 把确认放在收尾，是因为它的安装是用户级的、要改 shell 启动文件，
# 拒签必须把已装目录与 PATH 行一起删掉。这里放在最前面，拒签时系统一个字节都
# 没被碰过，「未安装任何内容」是字面意义上的真话，而不是一句安慰。
#
# 三道门，按顺序：
#   1. --accept-license  → 显式同意，不再问（给脚本与自动化用）
#   2. FINX_TEST 沙箱    → 自动同意并说明（那里本来就不会碰真实系统）
#   3. 其余              → 读 /dev/tty 问一次
#
# 为什么读 /dev/tty 而不是 stdin：`curl | sudo bash` 时 stdin 是脚本自身，
# 读它会吃掉脚本剩下的内容。这也是 MacWave 用 /dev/tty 的原因。
license_gate() {
    if [ "$ACCEPT_LICENSE" -eq 1 ]; then
        info "$(t 'agreement accepted with --accept-license' '已用 --accept-license 接受协议')"
        return 0
    fi

    if [ -n "${FINX_TEST:-}" ]; then
        info "$(t 'sandbox run: the agreement is accepted automatically' \
                 '沙箱运行：自动接受协议')"
        return 0
    fi

    warn "$(t 'Finx is released under the GPL v2. Read both files before you agree:
    LICENSE   which part of the tree carries which grant
    COPYING   the licence text itself
    https://finx.sh/#license-en' \
     'Finx 以 GPL v2 发布。同意之前请先读这两个文件：
    LICENSE   哪些目录适用哪个授权
    COPYING   许可证正文
    https://finx.sh/#license')"

    # 不能用 `[ -r /dev/tty ]`：那查的是权限，而设备节点谁都「可读」。
    # 没有控制终端时 access(R_OK) 仍然成功，打开才失败（ENXIO）。
    # 实测过：写成 [ -r ] 时门形同虚设，`curl | sudo bash` 会直接越过协议确认。
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        die "$(t 'no terminal to ask for agreement, so --accept-license is required.
Re-run interactively, or pass --accept-license after reading both files.' \
         '没有终端可以询问协议，因此必须显式传入 --accept-license。
请改为交互运行，或在读过这两个文件后传入 --accept-license。')"
    fi

    printf '%s ' "$(t 'Have you read and agree to it? [Y/n]' '你是否已阅读并同意？[Y/n]')" >&3
    answer=""
    read -r answer <&3 || answer=""
    exec 3<&-

    case $answer in
        ''|y|Y|yes|YES) info "$(t 'agreement accepted' '已记录你的同意')" ;;
        *) die "$(t 'you did not accept the agreement; nothing was installed.' \
                   '你未同意该协议，未安装任何内容。')" ;;
    esac
}

# 中英对照。--zh（或 FINX_LANG=zh）时取中文，否则取英文。
#
# 只覆盖安装器自己的话：step 标题、错误、以及收尾提示。curl 的进度条、
# 编译器的输出、bootstrap 的日志一律保持原样 —— 那些不是我们的话，
# 翻译它们只会让搜索报错变得更难。
t() {
    if [ "${ZH:-0}" -eq 1 ]; then
        printf '%s' "$2"
    else
        printf '%s' "$1"
    fi
}

info() {
    printf '    %s\n' "$*"
}

warn() {
    if [ "${ZH:-0}" -eq 1 ]; then
        printf '警告: %s\n' "$*" >&2
    else
        printf 'WARNING: %s\n' "$*" >&2
    fi
}

die() {
    if [ "${ZH:-0}" -eq 1 ]; then
        printf '错误: %s\n' "$*" >&2
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require() {
    have "$1" || die "required command not found: $1"
}

# 统一的执行入口。目前只是原样执行；留着是为了以后加日志或计时
# 时不必改几十处调用点。
run() {
    "$@"
}

ensure_tmp() {
    if [ -z "$FINX_TMP" ]; then
        # macOS 的 TMPDIR 自带末尾斜杠，直接拼会得到 "T//finx-install"
        tmpbase=${TMPDIR:-/tmp}
        while [ "${tmpbase%/}" != "$tmpbase" ]; do tmpbase=${tmpbase%/}; done
        [ -n "$tmpbase" ] || tmpbase=/tmp
        FINX_TMP=$(mktemp -d "$tmpbase/finx-install.XXXXXX") \
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

    # 沙箱里装的都是假东西，源码自举那条路不该向用户要 root
    IN_TEST_ROOT=1

    # 沙箱也绝不能碰真的 shell 配置。FINX_TEST 只管前缀与 TMPDIR，而收尾
    # 会往 $HOME 的启动文件里写 PATH —— 不拦的话，跑一次自测就改了开发者
    # 本人的 .zprofile。写 PATH 那条逻辑由 selftest 用假 HOME 单独测。
    NO_PATH=1

    if [ "${PREFIX_EXPLICIT:-0}" -eq 1 ]; then
        prefix_real=$(resolve_path "$PREFIX")
        case $prefix_real in
            "$TEST_ROOT"/*) ;;
            *) die "--prefix must live under FINX_TEST ($TEST_ROOT), got $prefix_real" ;;
        esac
    else
        PREFIX=$TEST_ROOT/opt/finx
    fi

    info "$(t 'test root' '测试根'): $TEST_ROOT $(t '(nothing outside it will be touched)' '（其外不会被改动）')"
}
