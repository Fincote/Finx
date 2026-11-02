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
# 源码回落：没有可用种子时，直接取源码树并跑它自带的 bootstrap。
#
# 为什么需要这条路：种子是「一台参考机上 bootstrap 成功之后的 /opt/finx 快照」。
# 在种子发布之前，一条命令要能用，只能退回到自举本身 —— 代价是要 Xcode
# Command Line Tools，且首次要现编 tar 与 dpkg。
#
# 无人值守：bootstrap 的所有提问都走 Fink::CLI::get_input，读到 EOF 时返回空串，
# 而每个提问都把空串解释成「取默认值」。所以把 stdin 接到 /dev/null 就等于
# 全程回车 —— 不需要改 Fink 内核，也不需要维护第二套交互逻辑。

# 源码归档位置。codeload 与 GitHub 网页的「Download ZIP」是同一个后端，
# 但返回 tar.gz，省掉解压 zip 的工具依赖。
default_source_url() {
    printf '%s/tar.gz/%s\n' "$FINX_SOURCE_DOMAIN" "${SOURCE_REF:-main}"
}

# 取并解源码树，设置 SOURCE_ROOT 为解出来的顶层目录。
fetch_source() {
    ensure_tmp

    src_url=${SOURCE_URL:-$(default_source_url)}
    info "source $src_url"

    SOURCE_ARCHIVE=$FINX_TMP/finx-source.tar.gz
    fetch_one "$src_url" "$SOURCE_ARCHIVE" \
        || die "cannot download the source archive from $src_url"

    SOURCE_ROOT=$FINX_TMP/src
    mkdir -p "$SOURCE_ROOT" || die "cannot create $SOURCE_ROOT"
    tar -xzf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT" \
        || die "cannot extract $SOURCE_ARCHIVE"

    # 归档里只有一个顶层目录（Finx-<ref>/），把它找出来
    set -- "$SOURCE_ROOT"/*
    [ $# -eq 1 ] && [ -d "$1" ] || die "unexpected layout in the source archive"
    SOURCE_ROOT=$1

    [ -f "$SOURCE_ROOT/bootstrap" ] \
        || die "the source archive does not contain bootstrap"
    [ -f "$SOURCE_ROOT/VERSION" ] \
        || die "the source archive does not contain VERSION"
    info "source tree $(cat "$SOURCE_ROOT/VERSION" 2>/dev/null) at $SOURCE_ROOT"
}

# 自举的硬要求，先查再跑：免得等了半小时才在某个 make 里失败。
require_bootstrap_prerequisites() {
    [ -x /usr/bin/cc ] || die "no C compiler at /usr/bin/cc; install the Xcode Command Line Tools
       (xcode-select --install) and try again"
    [ -x /usr/bin/pod2man ] || die "no /usr/bin/pod2man; bootstrap needs it to build man pages"
    [ -x /usr/bin/perl ] || die "no /usr/bin/perl; bootstrap is a Perl script"
}

# 跑 bootstrap。第一次自举会现编 tar 与 dpkg，慢是正常的。
run_bootstrap() {
    target=$1

    require_bootstrap_prerequisites

    # bootstrap 自己会在非 root 时提问并 exec sudo，但那时 stdin 已是 /dev/null，
    # sudo 读不到密码。所以先提权，让 bootstrap 一进来就是 root。
    # 数组而不是拼字符串：代理地址里可能有空格或特殊字符，靠词分割会散架。
    sudo_cmd=()
    if [ "$(id -u)" -ne 0 ]; then
        if [ "${IN_TEST_ROOT:-0}" -eq 1 ]; then
            # 测试根里装的都是假东西，不需要真 root
            :
        else
            have sudo || die "root is required and sudo is not available"
            # sudo 从 /dev/tty 读密码，所以 stdin 接 /dev/null 也不影响
            sudo -v || die "could not obtain sudo privileges"
            sudo_cmd=(sudo)
        fi
    fi

    # 代理变量必须显式传进去：sudo 默认会重置环境，而 bootstrap 里 Fink 自己的
    # 下载是以 root 跑的。用户明明配了代理、curl 也通，却会卡在下载那一步，
    # 报的错还只会说「连不上」。
    proxy_vars=()
    for name in http_proxy https_proxy all_proxy no_proxy \
                HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
        if [ -n "${!name:-}" ]; then
            proxy_vars+=("$name=${!name}")
        fi
    done
    if [ "${#proxy_vars[@]}" -gt 0 ] && [ "${#sudo_cmd[@]}" -gt 0 ]; then
        sudo_cmd=(sudo env "${proxy_vars[@]}")
        info "passing ${#proxy_vars[@]} proxy variable(s) through sudo"
    fi

    ensure_tmp
    bootstrap_log=$FINX_TMP/bootstrap.log

    info "compiling tar and dpkg; this is the slow path"
    info "  log: $bootstrap_log"

    # ${arr[@]+"${arr[@]}"} 而不是 "${arr[@]}"：bash 3.2 在 set -u 下展开空数组
    # 会报 unbound variable（4.4 才修好）。而以 root 运行、或测试根里，
    # sudo_cmd 正好是空的。
    #
    # 默认把 bootstrap 的全部输出收进日志：它会逐条打印 mkdir、编译每一行、还有
    # 出错时的那套「该找哪个邮件列表」模板，几百行下去把真正要看的三行冲掉。
    # 失败时只回放末尾，够定位；要看全程就 --verbose。
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        ( cd "$SOURCE_ROOT" && ${sudo_cmd[@]+"${sudo_cmd[@]}"} ./bootstrap "$target" < /dev/null ) \
            2>&1 | tee "$bootstrap_log"
        rc=${PIPESTATUS[0]}
    else
        ( cd "$SOURCE_ROOT" && ${sudo_cmd[@]+"${sudo_cmd[@]}"} ./bootstrap "$target" < /dev/null ) \
            > "$bootstrap_log" 2>&1
        rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        printf '\n' >&2
        printf 'The last lines of %s:\n' "$bootstrap_log" >&2
        tail -n 40 "$bootstrap_log" >&2 2>/dev/null || true
        printf '\n' >&2
        die "bootstrap failed (full log: $bootstrap_log)"
    fi
}
