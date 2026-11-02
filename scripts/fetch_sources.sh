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
# fetch_sources.sh - 把 bootstrap 需要的源码包下到一个目录，供离线安装
#
# 用法：
#   ./scripts/fetch_sources.sh <output-dir>
#
# 拿 U 盘去目标机器的用法见 docs/OFFLINE.md。
#
# 为什么这样就够了：Fink 的 find_tarball（PkgVersion.pm:2466）第一个搜索目录
# 就是 $basepath/src。文件在那儿，bootstrap 完全不联网。
#
# 需要哪些包：tar-bootstrap、dpkg-bootstrap，加上每个 `Essential: yes` 的包。
# 这就是 bootstrap1 里 @plist 与 list_essential_packages() 的并集 —— 直接读
# .info 比复现 Fink 的 Perl 运行时状态可靠得多（那条路需要一个初始化好的
# $config，在仓库外很难搭起来）。
#
# 每个文件下完立刻验证：压缩包要能解开，且与 .info 里登记的校验和一致。
# 镜像返回「200 + HTML 错误页」是发生过的真事，光看 curl 退出码不够。

set -u

HERE=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
REPO=$(cd -- "$HERE/.." && pwd) || exit 1
cd "$REPO" || exit 1

OUT=${1:-}
if [ -z "$OUT" ]; then
    printf 'usage: %s <output-dir>\n' "$(basename "$0")" >&2
    exit 2
fi
mkdir -p "$OUT" || exit 1
OUT=$(cd "$OUT" && pwd) || exit 1

MIRROR=http://distfiles.master.finkmirrors.net/distfiles
CPAN=https://cpan.metacpan.org

# ---- 1. 要哪些包 ---------------------------------------------------------

PKGS="tar-bootstrap dpkg-bootstrap $(grep -l '^Essential:[[:space:]]*yes' 10.9-libcxx/*.info 2>/dev/null \
    | sed 's|.*/||;s|\.info$||' | tr '\n' ' ')"

printf 'packages: %s\n\n' "$PKGS" >&2

# ---- 2. 解析 Source 并翻成候选 URL --------------------------------------

sources_of() {
    sed -n 's/^Source[0-9]*:[[:space:]]*//p' "10.9-libcxx/$1.info" 2>/dev/null \
        | sed 's/^"//;s/"$//' | grep -v '^$' | grep -v '\.patch$'
}

urls_of() {
    spec=$1
    base=${spec##*/}
    case $spec in
        mirror:custom:*)
            printf '%s\n' "$MIRROR/$base"
            printf '%s\n' "http://downloads.sourceforge.net/${spec#mirror:custom:}"
            ;;
        mirror:sourceforge:*)
            printf '%s\n' "http://downloads.sourceforge.net/${spec#mirror:sourceforge:}"
            printf '%s\n' "$MIRROR/$base"
            ;;
        mirror:cpan:*)
            printf '%s\n' "$CPAN/${spec#mirror:cpan:}"
            ;;
        mirror:master:*)
            printf '%s\n' "$MIRROR/$base"
            ;;
        http://*|https://*|ftp://*)
            printf '%s\n' "$spec"
            ;;
    esac

    # 上游官方兜底。这两个包在 finkmirrors 上返回的是 HTML 错误页（200 但内容
    # 是 <!DOCTYPE html>），实测过。
    case $base in
        expat-*.tar.bz2)
            v=${base#expat-}; v=${v%.tar.bz2}
            printf '%s\n' "https://github.com/libexpat/libexpat/releases/download/R_$(echo "$v" | tr . _)/$base"
            ;;
        binutils-*.tar.xz)
            printf '%s\n' "https://mirrors.kernel.org/gnu/binutils/$base"
            ;;
    esac
}

# ---- 3. 期望的校验和 -----------------------------------------------------

expected_sum() {
    f=10.9-libcxx/$1.info
    md5=$(sed -n 's/^Source-MD5:[[:space:]]*//p' "$f" 2>/dev/null | head -1)
    sha=$(sed -n 's/^Source-Checksum:[[:space:]]*SHA256(\([0-9a-f]*\)).*/\1/p' "$f" 2>/dev/null | head -1)
    printf '%s %s\n' "${md5:-}" "${sha:-}"
}

check_file() {
    file=$1; md5=$2; sha=$3
    case $file in
        *.tar.gz|*.tgz) gzip -t "$file" 2>/dev/null || return 1 ;;
        *.tar.bz2)      bzip2 -t "$file" 2>/dev/null || return 1 ;;
        *.tar.xz)       xz -t "$file" 2>/dev/null || return 1 ;;
    esac
    if [ -n "$sha" ]; then
        [ "$(shasum -a 256 "$file" | awk '{print $1}')" = "$sha" ] || return 1
    elif [ -n "$md5" ]; then
        [ "$(md5 -q "$file" 2>/dev/null)" = "$md5" ] || return 1
    fi
    return 0
}

# ---- 4. 下载 -------------------------------------------------------------

got=0; skipped=0; failed=0

for pkg in $PKGS; do
    [ -f "10.9-libcxx/$pkg.info" ] || continue

    for spec in $(sources_of "$pkg"); do
        base=${spec##*/}
        case $base in
            *.tar.gz|*.tar.bz2|*.tar.xz|*.tgz|*.zip|*.tar) ;;
            *) continue ;;
        esac

        if [ -f "$OUT/$base" ]; then
            printf 'have %-32s\n' "$base" >&2
            skipped=$((skipped + 1))
            continue
        fi

        sums=$(expected_sum "$pkg")
        md5=${sums%% *}
        sha=${sums##* }

        ok=0
        while IFS= read -r url; do
            [ -n "$url" ] || continue
            printf '  %-32s ' "$base" >&2
            if curl -fsSL -C - --connect-timeout 20 -m 900 \
                    -o "$OUT/$base.part" "$url" 2>/dev/null; then
                mv -f "$OUT/$base.part" "$OUT/$base"
                if check_file "$OUT/$base" "$md5" "$sha"; then
                    printf 'ok (%s)\n' "$(wc -c < "$OUT/$base" | tr -d ' ')" >&2
                    ok=1; got=$((got + 1)); break
                fi
                printf 'BAD content\n' >&2
                rm -f "$OUT/$base"
            else
                rm -f "$OUT/$base.part"
                printf 'no (%s)\n' "$(echo "$url" | sed 's|.*://||;s|/.*||')" >&2
            fi
        done < <(urls_of "$spec")

        [ "$ok" -eq 1 ] || { printf 'MISSING %s (needed by %s)\n' "$base" "$pkg" >&2; failed=$((failed + 1)); }
    done
done

# ---- 5. 清单 -------------------------------------------------------------

{
    printf '# prepared by scripts/fetch_sources.sh\n'
    printf '# copy the archives into <prefix>/src on the target machine\n'
    ls -1 "$OUT" 2>/dev/null \
        | grep -E '\.(tar\.gz|tar\.bz2|tar\.xz|tgz|zip|tar)$' \
        | while IFS= read -r f; do
            printf '%s  %s\n' "$(shasum -a 256 "$OUT/$f" | awk '{print $1}')" "$f"
        done
} > "$OUT/SHA256SUMS"

printf '\n%d new, %d already present, %d could not be fetched\n' \
    "$got" "$skipped" "$failed" >&2
printf 'output: %s\n' "$OUT" >&2
[ "$failed" -eq 0 ] || exit 1
