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
# perl_check.sh - 每个 Perl 文件都必须能在系统 Perl 5 下编译
#
# 这个项目是 Perl 5。Perl 6 后来改名 Raku，是**另一门语言**，两者除了名字没有
# 关系。有人照着网上「Perl 教程」写出 `use v6` 或 `class Foo { ... }` 时，绝大多数
# 情况会直接语法失败 —— 但也有少数写法在 Perl 5 里能解析、只是含义完全不同，
# 那种最麻烦：不报错，行为不是作者想的那个样子。
#
# 所以这里做两件事，缺一不可：
#
#   1. 先按**标记**查。`use v6`、`unit module/class/role`、`.raku`/`.p6` 之类
#      一眼可辨，报错信息才能说人话（"这是 Raku 不是 Perl 5"），而不是把
#      perl -c 的原始输出丢给贡献者。
#   2. 再逐个 `perl -c`。这一步才是真正的门槛：它用真实解释器判定，无法绕过。
#      标记清单总会漏，编译器不会。
#
# 覆盖范围必须是「仓库里所有 Perl」，不能只看 perlmod/ —— bootstrap 本身、
# t/ 下的测试、以及 *.pl 脚本同样是 Perl。之前 CI 只编 perlmod/**/*.pm，
# 于是 bootstrap 与 48 个 .t 文件从来没被检查过。
#
# .in 模板（postinstall.pl.in 之类）带着 @PREFIX@ 占位符，直接编译会被当成
# 数组插值。这里先把占位符替换成一个安全值再编译，仍然能查出真正的语法错误。

set -u

HERE=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
REPO=$(cd -- "$HERE/.." && pwd) || exit 1
cd "$REPO" || exit 1

PERL=/usr/bin/perl
[ -x "$PERL" ] || { printf 'perl_check: no %s\n' "$PERL" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/finx-perlcheck.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

fail=0
count=0

# 判定只看 shebang 与扩展名，与 scripts/format_check.pl 的做法一致：
# .in 里既有 Perl 也有 shell，不能按扩展名一刀切。
# 仓库里用 git 清单；载荷树（bootstrap 的 CompileScript 里跑 make test 的那棵）
# 没有 .git，改用 MANIFEST —— 那是载荷的权威清单，不会漏也不会带进 .deb。
collect_perl_files() {
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git ls-files
    elif [ -f MANIFEST ]; then
        sed -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' MANIFEST
    else
        find . -type f -not -path './.git/*'
    fi
}

# ---- 1. Perl 6 / Raku 标记 -------------------------------------------------

# 文件扩展名就写着 Raku 的，直接拒。
while IFS= read -r f; do
    case $f in
        *.p6|*.pm6|*.pl6|*.raku|*.rakumod|*.rakudoc|*.t6)
            printf 'perl_check: %s\n' "$f"
            printf 'perl_check: 这个扩展名是 Raku（Perl 6）的，本项目只写 Perl 5\n' >&2
            fail=1 ;;
    esac
done < <(collect_perl_files)

# 内容是 Raku 的。只在 Perl 文件里查，避免误伤文档与 .info。
while IFS= read -r f; do
    case $f in
        *.pm|*.pm.in|*.pl|*.pl.in|*.t) ;;
        *)
            head -1 "$f" 2>/dev/null | grep -q '^#!.*perl' || continue ;;
    esac
    hits=$(grep -nE '^[[:space:]]*use[[:space:]]+v6([^0-9]|$)|^[[:space:]]*unit[[:space:]]+(module|class|role|grammar)[[:space:]]|^[[:space:]]*(grammar|subset)[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\{|^[[:space:]]*multi[[:space:]]+(sub|method)[[:space:]]|^[[:space:]]*role[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\{' "$f" 2>/dev/null)
    if [ -n "$hits" ]; then
        printf 'perl_check: %s\n' "$f"
        printf '%s\n' "$hits" | sed 's/^/perl_check:   /' >&2
        printf 'perl_check: 这些是 Raku（Perl 6）语法，Perl 5 不认。请改写成 Perl 5\n' >&2
        fail=1
    fi
done < <(collect_perl_files)

# ---- 2. 真实编译 -----------------------------------------------------------

while IFS= read -r f; do
    # .in 模板里既有 Perl 也有 shell（editor.in、init.csh.in 是 shell）。
    # 先替换占位符，再按替换后的 shebang（或扩展名）判定语言，不能按后缀一刀切。
    src=$f
    case $f in
        *.in)
            # 占位符分两类：
            #   @PREFIX@ / @PROG@ 在字符串里（"@PREFIX@/var/..."），替换成裸词
            #   @PACKARGS@ 在表达式里（pack(@PACKARGS@, ...)），必须带引号，
            #               否则裸词在 use strict 下直接报错
            sed -e 's/@PACKARGS@/"i4"/g' \
                -e 's/@[A-Za-z_][A-Za-z0-9_]*@/X/g' "$f" > "$WORK/tmpl" \
                || { fail=1; continue; }
            src=$WORK/tmpl ;;
    esac

    case $src in
        *.pm|*.pm.in|*.pl|*.pl.in|*.t) ;;
        *)
            head -1 "$src" 2>/dev/null | grep -q '^#!.*perl' || continue ;;
    esac

    # 带 -T 的脚本必须同样在命令行上给 -T，否则 perl -c 直接报错
    flags=""
    head -1 "$src" 2>/dev/null | grep -q '^#!.*perl.*[[:space:]]-T' && flags="-T"

    count=$((count + 1))
    if ! out=$("$PERL" $flags -I perlmod -c "$src" 2>&1); then
        printf 'perl_check: %s\n' "$f"
        printf '%s\n' "$out" | sed 's/^/perl_check:   /' >&2
        fail=1
    fi
done < <(collect_perl_files)

if [ "$fail" -ne 0 ]; then
    printf '\nperl_check: FAILED\n' >&2
    exit 1
fi
printf 'perl syntax OK (%s files)\n' "$count"
