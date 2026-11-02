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
# license_check.sh - 守住 LICENSE 里那张范围表，不让它随时间失真
#
# LICENSE 说明这个仓库有两个许可段：取自 Fink 的保持 GPL-2.0-or-later，
# 我们自己写的用 GPL-2.0-only。那张表是人写的，会旧。这个脚本把它的三条
# 硬规则变成机检。
#
# 为什么必须是机检：这三条错了都不会让任何测试变红，也不会让任何功能失效 ——
# 它们只在有人认真追究授权时才有后果。那种错误靠自觉发现不了。
#
# 判定只看每个文件开头的声明行，因为 GPL 第二版的条文对 only 与 or later 是
# 同一份，差别只在声明。
#
# 三条规则：
#
#   1. 带 Fink 版权行的文件，不得声明 v2-only。
#      Fink 给的是 or-later，收窄别人的授权不是我们能做的决定。
#      这类错误最需要拦住：它看起来只是一行措辞，实际是越权。
#
#   2. 声明了授权、却没有任何版权行 —— 授权给谁？这是笔误。
#
#   3. 只有我们署名的文件，应当声明 v2-only。
#      项目约定新写的代码用第二版、不含「或任何更新版本」。
#
# 完全没有任何版权行的文件（大量 t/*.t 与生成模板）不在检查范围内：
# 要求所有文件都加头是一次大改造，与这里要防的风险不成比例。

set -u

HERE=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
REPO=$(cd -- "$HERE/.." && pwd) || exit 1
cd "$REPO" || exit 1

# git 清单优先；载荷树没有 .git，改用 MANIFEST
collect() {
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git ls-files
    elif [ -f MANIFEST ]; then
        sed -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' MANIFEST
    else
        find . -type f -not -path './.git/*'
    fi
}

# 只看源码与脚本，文档与 .info 的许可由它们各自的上游决定
is_source() {
    case $1 in
        *.pm|*.pm.in|*.pl|*.pl.in|*.t|*.sh|*.sh.in) return 0 ;;
        bootstrap|setup.sh|install.sh|finx.sh) return 0 ;;
    esac
    return 1
}

FINK_RE='Copyright \(c\) [0-9]{4}(-[0-9]{4})? (The Fink Package Manager Team|The Fink Team|Christoph Pfisterer)'
OURS_RE='Copyright \(c\) [0-9]{4} Sha0huaZhang'

errors=0
n_later=0
n_only=0
n_none=0

report() {
    printf 'license_check: %s\n' "$1" >&2
    printf '%s\n' "$2" | sed 's/^/license_check:   /' >&2
    errors=$((errors + 1))
}

while IFS= read -r f; do
    is_source "$f" || continue
    [ -f "$f" ] || continue

    head30=$(head -30 "$f" 2>/dev/null) || continue

    fink=0; printf '%s' "$head30" | grep -qE "$FINK_RE" && fink=1
    ours=0; printf '%s' "$head30" | grep -qE "$OURS_RE" && ours=1
    # 规则 2 只关心「有没有人署名」，不关心是谁。第三方文件常用别的写法
    # （`Copyright (C) 1996-1999 Free Software Foundation, Inc.`），
    # 拿 Fink/我们的正则去匹配会误判成「无版权行」。
    any=0; printf '%s' "$head30" | grep -qi 'copyright' && any=1

    # 声明常常折行，直接 grep 整句会漏：
    #
    #     # as published by the Free Software Foundation; version 2
    #     # of the License.
    #
    # "version 2 of the License" 被换行切开，判定成 none，规则 1 就形同虚设。
    # 所以先把注释标记去掉、把空白压成单空格，再匹配。
    flat=$(printf '%s' "$head30" | sed 's/^[[:space:]]*#//' | tr '\n' ' ' | tr -s ' ')

    grant=none
    case $flat in
        # 先判 or-later：它的句式里也含 "version 2 of the License"
        *"either version 2"*) grant=later ;;
        *"version 2 of the License"*|*"version 2 of this License"*) grant=only ;;
    esac
    case $grant in
        later) n_later=$((n_later + 1)) ;;
        only)  n_only=$((n_only + 1)) ;;
        *)     n_none=$((n_none + 1)) ;;
    esac

    # 规则 1
    if [ "$fink" -eq 1 ] && [ "$grant" = only ]; then
        report "带 Fink 版权行的文件声明了 v2-only —— 这是收窄上游授权" \
"$f
   Fink 给的是 GPL-2.0-or-later。保留它原来的措辞，只追加一行 Copyright。
   See LICENSE, section 'Adding or modifying files'."
        continue
    fi

    # 规则 2
    if [ "$grant" != none ] && [ "$any" -eq 0 ]; then
        report "声明了授权，但没有任何版权行" \
"$f
   补一行 Copyright (c) <年份> <作者> <邮箱>，否则「授权给谁」是空的。"
        continue
    fi

    # 规则 3
    if [ "$grant" = later ] && [ "$fink" -eq 0 ] && [ "$ours" -eq 1 ]; then
        report "只有我们署名的文件却声明了 or-later" \
"$f
   New files use v2-only: drop the phrase 'or (at your option) any later version'.
   Copy the header from scripts/make_seed.sh."
        continue
    fi
done < <(collect)

if [ "$errors" -ne 0 ]; then
    printf '\nlicense_check: FAILED (%s file(s))\n' "$errors" >&2
    exit 1
fi

printf 'license OK (%s or-later, %s only, %s without a header)\n' \
    "$n_later" "$n_only" "$n_none"
