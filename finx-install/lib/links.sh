#
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
# 载荷自带的符号链接，解析后必须落在安装根目录内。
# 由 install.sh 以 . 方式加载，不单独执行。
#
# 为什么需要这条：解包工具只过滤成员**名字**里的 "../"，与链接的**目标**无关。
# 一个产物可以合法地含有
#
#     lib/innocent.dylib -> /Users/someone/.ssh/id_rsa
#
# 名字老实待在树内，指向的地方却是任何位置。装完之后，任何顺着这个链接去读或
# 去写的代码 —— 重签名、写配置、日后卸载时的 rm -rf —— 都会落到树外。
#
# 唯一开口子的地方是系统库位置，两条理由必须同时成立才给：SIP 连 root 都拒绝
# 写这些路径（顺着链接写不成立），且那里只有系统自带的二进制与库、不含隐私文件
# （顺着链接读也不成立）。其余一律不例外，包括 /Users、/Library 里 Apple/ 以外的
# 部分、/private、/opt、/etc、/var：都有用户数据，且大多不受 SIP 保护。
#
# 判定按**路径分段**比较，不是字符串前缀："$root/../evil" 归一化之后是 "$root/evil"，
# 而 "/opt/finx2" 不会被当成 "/opt/finx" 的子目录。

FINX_LINK_EXEMPT="/bin /sbin /usr/bin /usr/sbin /usr/lib /usr/libexec /System /Library/Apple"

# 把路径按段归一化：吃掉空段与 "."，".." 弹出一段。
#
# 只用字符串操作，不碰文件系统 —— 悬空链接照样要判定：一个指向 /opt/nothing-here
# 的悬空链接，等目标出现时就变成真越界了。调用方保证传入绝对路径。
canon_path() {
    _rest=$1
    _out=""
    while [ -n "$_rest" ]; do
        case $_rest in
            */*) _seg=${_rest%%/*}; _rest=${_rest#*/} ;;
            *)   _seg=$_rest; _rest="" ;;
        esac
        case $_seg in
            ''|.) ;;
            ..) _out=${_out%/*} ;;
            *)  _out="$_out/$_seg" ;;
        esac
    done
    printf '%s' "${_out:-/}"
}

# 列出 $root 下解析后落在 $root 与豁免表之外的链接，每条一行："路径 -> 目标"。
# 没有越界链接时输出为空。路径相对于 $root，便于阅读。
offending_links() {
    _root=$(canon_path "$1")
    while IFS= read -r _link; do
        [ -n "$_link" ] || continue
        _target=$(readlink "$_link" 2>/dev/null) || continue
        case $_target in
            /*) _resolved=$(canon_path "$_target") ;;
            *)  _resolved=$(canon_path "$(dirname "$_link")/$_target") ;;
        esac

        _ok=0
        case $_resolved in
            "$_root"|"$_root"/*) _ok=1 ;;
        esac
        if [ "$_ok" -eq 0 ]; then
            for _ex in $FINX_LINK_EXEMPT; do
                case $_resolved in
                    "$_ex"|"$_ex"/*) _ok=1; break ;;
                esac
            done
        fi

        [ "$_ok" -eq 1 ] || printf '%s -> %s\n' "${_link#"$_root"/}" "$_target"
    done <<EOF
$(find "$_root" -type l 2>/dev/null)
EOF
}
