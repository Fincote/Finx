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

OURS=https://github.com/Fincote/Finx-source/releases/download/src-1
MIRROR=http://distfiles.master.finkmirrors.net/distfiles
CPAN=https://cpan.metacpan.org

# ---- 1. 要哪些包 ---------------------------------------------------------

# 要哪些包：凡是 CustomMirror 指向我们镜像的那些。这是最准确的判据 ——
# 我们镜像里放的就是它们需要的源码，不多不少。用 Essential 列表会漏掉
# expat1、texinfo、objtools 这类「不是 Essential 但 bootstrap 要装」的包，
# 第一版就是这么漏掉 6 个的。
PKGS=$(grep -l "^Primary: $OURS\$" 10.9-libcxx/*.info 2>/dev/null \
    | sed 's|.*/||;s|\.info$||' | sort | tr '\n' ' ')

printf 'packages: %s\n\n' "$PKGS" >&2

# ---- 2. 解析 Source 并翻成候选 URL --------------------------------------

sources_of() {
    sed -n 's/^Source[0-9]*:[[:space:]]*//p' "10.9-libcxx/$1.info" 2>/dev/null \
        | sed 's/^"//;s/"$//' | grep -v '^$' | grep -v '\.patch$'
}

# Source: 里的 %n / %v 是占位符，不是文件名。不展开就会去下
# 「%n-%v.tar.gz」这种不存在的路径 —— 这个 bug 写出来时就有，实测才发现。
expand_spec() {
    spec=$1
    name=$2
    ver=$3
    printf '%s\n' "$spec" | sed -e "s|%n|$name|g" -e "s|%v|$ver|g"
}

urls_of() {
    spec=$1
    # 先剥掉 mirror:<名字>: 前缀再取 basename。`mirror:custom:bzip2-1.0.6.tar.gz`
    # 里根本没有斜杠，直接 ${spec##*/} 会把整个规格当成文件名 —— 这个 bug 让
    # 第一版脚本去下了「mirror:custom:%n-%v.tar.gz」这种不存在的路径。
    base=$(printf '%s\n' "$spec" | sed 's|^mirror:[a-z0-9]*:||')
    base=${base##*/}
    # 我们自己的镜像放第一位：它是唯一一个能保证可达的来源，
    # 其余都是兜底。见 docs/MIRRORS.md。
    printf '%s\n' "$OURS/$base"

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
            printf '%s\n' "https://mirrors.tuna.tsinghua.edu.cn/gnu/binutils/$base"
            printf '%s\n' "https://mirrors.kernel.org/gnu/binutils/$base"
            ;;
        gettext-*.tar.gz)
            printf '%s\n' "https://mirrors.tuna.tsinghua.edu.cn/gnu/gettext/$base"
            ;;
    esac
}

# ---- 3. 期望的校验和 -----------------------------------------------------

# 字段名与算法名并不总是一致：dpkg-bootstrap.info 写的是
#   Source-MD5: SHA256(b50e58b7...)
# 而 dpkg.info 写的是
#   Source-Checksum: SHA256(b50e58b7...)
# 所以按「值长什么样」判断算法，不按字段名。
expected_sum() {
    f=10.9-libcxx/$1.info
    raw=$(sed -n -e 's/^Source-MD5:[[:space:]]*//p' -e 's/^Source-Checksum:[[:space:]]*//p' \
        "$f" 2>/dev/null | head -1)
    md5=""; sha=""
    case $raw in
        SHA256\(*\))  sha=${raw#SHA256(}; sha=${sha%)} ;;
        MD5\(*\))     md5=${raw#MD5(};    md5=${md5%)} ;;
        *)
            case $raw in
                *[!0-9a-fA-F]*) ;;                       # 不是纯十六进制，忽略
                *) case ${#raw} in
                    32) md5=$raw ;;
                    64) sha=$raw ;;
                esac ;;
            esac ;;
    esac
    printf '%s %s\n' "$md5" "$sha"
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

    # 本仓库自己打包的源码（如 base-files）由 pack.sh 就地生成，没有上游 tar 可下。
    # bootstrap 会在下载之前跑 pack_included_sources 把它们放进 <prefix>/src。
    if [ -f "$REPO/$pkg/pack.sh" ]; then
        printf 'skip %-26s (packed locally by %s/pack.sh)\n' "$pkg" "$pkg" >&2
        continue
    fi

    ver=$(sed -n 's/^Version:[[:space:]]*//p' "10.9-libcxx/$pkg.info" | head -1)
    [ -n "$ver" ] || { printf 'skip %-26s (no Version)\n' "$pkg" >&2; continue; }

    for raw in $(sources_of "$pkg"); do
        spec=$(expand_spec "$raw" "$pkg" "$ver")
        base=$(printf '%s\n' "$spec" | sed 's|^mirror:[a-z0-9]*:||')
        base=${base##*/}
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
