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
# make_seed.sh - 把一个装好的前缀打成种子，并写出配套的清单
#
# 安装侧的 `finx-install/install.sh` 拿到种子后只做四件事：解包到前缀、
# 归一权限、重签 Mach-O、写配置并重建索引。所以种子就是「一个能用的前缀」，
# 而不是 .deb 池 —— 池里的东西 dpkg 已经装完了，再装一遍没有意义。
#
# 用法：
#   ./scripts/make_seed.sh --prefix /opt/finx --out dist/seed --release 0.46.0
#
#   --prefix DIR    已安装的前缀，默认 /opt/finx
#   --out DIR       产物目录，生成 seed.tar.gz 与 manifest
#   --release VER   写进清单的版本号；不给就读仓库根目录的 VERSION
#   --arch ARCH     写进清单的架构；默认取 uname -m
#   --url URL       写进清单的下载地址。**发布到 GitHub 时必须给**，否则
#                   清单里没有 url 行，安装器会回落到 FINX_SEED_DOMAIN
#                   （默认 https://finx.sh/finx/seed/seed.tar.gz）——它探得到
#                   清单、却下不到种子，静默失效。自建镜像时不给才是对的。
#   --force         覆盖已存在的产物
#
# 关于「可迁移性」，这一点必须说清楚，因为它决定了种子能装到哪儿：
#
#   dpkg 的 var/lib/dpkg/info/*.list 记的是绝对路径（/opt/finx/bin/...），
#   二进制里的 rpath 与 finx.conf 的 basepath 也是。所以种子只能装到它被
#   打出来时的那个前缀。装到别处不会当场报错，而是装出一个 dpkg 认为文件
#   在 /opt/finx、实际在多处的前缀。
#
#   因此 --prefix 不是 /opt/finx 时会警告。这不是实现偷懒，是 dpkg 的语义。
#
# 关于「确定性」，与 base-files/pack.sh 的取舍不同：
#
#   那边必须逐字节稳定，因为 Source-MD5 写死在 .info 里，差一个字节 Fink
#   就判定下载被篡改。种子不需要 —— 清单里记的是**这一次**产物的 sha256，
#   每次构建换一份清单即可。
#
#   所以这里只做仍然有意义的归一：成员顺序、属主属组、gzip 头。时间戳无法
#   用 bsdtar 归一（3.5.3 不支持 --mtime），也不值得为了它去翻转整棵树的
#   mtime —— 那会破坏已安装前缀里文件的真实时间。

set -u

PREFIX=/opt/finx
OUT=
RELEASE=
ARCH=$(uname -m)
URL=
FORCE=0

# 不进入种子的东西，以及各自的理由。
#
#   src                       构建目录，是整棵树里最大的一块，装完就没用了
#   tmp                       安装器的临时文件
#   var/cache/apt/archives    apt 下载的 .deb 副本；成品在下面的池里，这里只是重复
#   var/log                   构建日志，属于构建机，不属于用户
#   etc/finx.conf             安装器会按实际前缀重写（write_config），
#                             带进种子反而会把 /opt/finx 钉死
#   .DS_Store                 构建机上 Finder 留下的东西
#
# 树本身不进 EXCLUDES。$prefix/finx/ 下是二进制池与描述树：
#
#   finx/10.9-libcxx/.../base/*.deb   实物
#   finx/26.0 -> 10.9-libcxx          按 macOS 版本命名的别名
#   finx/dists -> 26.0
#   finx/debs/<name>.deb -> ../26.0/...   给 dpkg / finx 用的扁平整名
#
# 这些全是**相对**符号链接，而且目标都在前缀内部，所以剔掉 src/ 不影响它们 ——
# 解包到任何地方都自洽。上面那条关于 debs 会断链的担心，是我按「链接指向
# buildpath」猜的；实际指向池子，实测 27 个链接全部可解析。
EXCLUDES="src tmp var/cache/apt/archives var/log etc/finx.conf .DS_Store"

die() {
    printf 'make_seed.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '/^# make_seed.sh/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case $1 in
        --prefix)  shift; [ $# -gt 0 ] || die "--prefix needs a value"; PREFIX=$1 ;;
        --prefix=*) PREFIX=${1#*=} ;;
        --out)     shift; [ $# -gt 0 ] || die "--out needs a value"; OUT=$1 ;;
        --out=*)   OUT=${1#*=} ;;
        --release) shift; [ $# -gt 0 ] || die "--release needs a value"; RELEASE=$1 ;;
        --release=*) RELEASE=${1#*=} ;;
        --arch)    shift; [ $# -gt 0 ] || die "--arch needs a value"; ARCH=$1 ;;
        --arch=*)  ARCH=${1#*=} ;;
        --url)     shift; [ $# -gt 0 ] || die "--url needs a value"; URL=$1 ;;
        --url=*)   URL=${1#*=} ;;
        --force)   FORCE=1 ;;
        -h|--help) usage ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

[ -n "$OUT" ] || die "--out is required"

# 先算到临时变量再赋值：写成 PREFIX=$(...)，失败时 $PREFIX 已经被赋成空串，
# 那句话就变成 "no such prefix: " —— 报错却不说哪个目录。
_resolved=$(cd "$PREFIX" 2>/dev/null && pwd) || die "no such prefix: $PREFIX"
PREFIX=$_resolved

# 两条就够判断「这是个装好的前缀而不是随便一个目录」。dpkg 的 status 尤其
# 关键：没有它，种子里就没有「装了什么」的记录，解出来是个死目录。
[ -x "$PREFIX/bin/finx" ] || die "$PREFIX does not look installed (no bin/finx)"
[ -f "$PREFIX/var/lib/dpkg/status" ] \
    || die "$PREFIX has no var/lib/dpkg/status; the seed would not know what is installed"

if [ -z "$RELEASE" ]; then
    REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
    RELEASE=$(cat "$REPO_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')
    [ -n "$RELEASE" ] || die "cannot read VERSION; pass --release"
fi

case $ARCH in
    ''|*[!a-zA-Z0-9_]*) die "--arch looks wrong: $ARCH" ;;
esac

if [ "$PREFIX" != /opt/finx ]; then
    printf 'WARNING: the seed is bound to the prefix it was built in (%s).\n' "$PREFIX" >&2
    printf 'WARNING: dpkg file lists and rpaths are absolute; it will only work at %s.\n' \
        "$PREFIX" >&2
fi

mkdir -p "$OUT" || die "cannot create $OUT"
SEED=$OUT/seed.tar.gz
MANIFEST=$OUT/manifest

if [ -e "$SEED" ] && [ "$FORCE" -ne 1 ]; then
    die "$SEED exists; pass --force to replace it"
fi

is_excluded() {
    _p=$1
    for _e in $EXCLUDES; do
        case $_p in
            "$_e"|"$_e"/*) return 0 ;;
        esac
    done
    return 1
}

# 成员名相对前缀，因为安装器解包时用的是 `tar -xzf ... -C $PREFIX`。
LIST=$(mktemp "${TMPDIR:-/tmp}/finx-seed-list.XXXXXX") || die "cannot create a temp file"
cleanup() { rm -f "$LIST" "$SEED.part"; }
trap cleanup EXIT

kept=0
dropped=0
(
    cd "$PREFIX" || exit 1
    # 排序是为了让同样的树打出一模一样的成员顺序。
    find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r p; do
        case $p in
            ._*) continue ;;
        esac
        if is_excluded "$p"; then
            printf 'x %s\n' "$p"
        else
            printf 'k %s\n' "$p"
        fi
    done
) > "$LIST.raw" || die "cannot walk $PREFIX"

sed -n 's/^k //p' "$LIST.raw" > "$LIST"
# grep -c 找不到匹配时自己会打印 0 **并返回 1**，所以后面不能接 || echo 0：
# 那样变量会变成两行 "0\n0"，printf 把它插进句子就断成两截。
# 实测：一个没有任何排除项的前缀打出来是 "packing 7 members (0" 换行 "0 excluded)"。
dropped=$(grep -c '^x ' "$LIST.raw" 2>/dev/null) || dropped=0
kept=$(wc -l < "$LIST" | tr -d ' ')
rm -f "$LIST.raw"

[ "$kept" -gt 0 ] || die "the prefix is empty after exclusions"

printf 'packing %s members (%s excluded) from %s\n' "$kept" "$dropped" "$PREFIX"

# COPYFILE_DISABLE=1：否则 macOS 会给带扩展属性的文件加上 ._ 影子成员。
# gzip -n：不写入原始文件名与时间戳，压缩头里不留构建机的痕迹。
# --no-recursion 必须给：列表里已经有每一个成员了，而 bsdtar 默认会对列进来的
# 目录再递归一遍 —— 结果既是重复成员，又会把 etc/finx.conf 这类被排除的文件
# 从父目录底下重新拉回来。
# 绝对路径：不信任 PATH 里的 tar。同 base-files/pack.sh 里那段事故说明 ——
# Fink 编的 GNU tar 在 /opt/finx/bin 里，不认 bsdtar 的 --uid。
if ! COPYFILE_DISABLE=1 /usr/bin/tar --format=ustar --no-recursion \
        --uid 0 --gid 0 --uname root --gname wheel \
        -cf "$SEED.part" -C "$PREFIX" -T "$LIST"; then
    rm -f "$SEED.part"
    die "tar failed"
fi
if ! /usr/bin/gzip -n -9 -f "$SEED.part"; then
    rm -f "$SEED.part" "$SEED.part.gz"
    die "gzip failed"
fi
mv -f "$SEED.part.gz" "$SEED" || die "cannot move the seed into place"

SIZE=$(wc -c < "$SEED" | tr -d ' ')
if command -v shasum >/dev/null 2>&1; then
    SHA=$(shasum -a 256 "$SEED" | awk '{print $1}')
else
    SHA=$(openssl dgst -sha256 "$SEED" | awk '{print $NF}')
fi
[ -n "$SHA" ] || die "cannot compute sha256"

{
    printf 'schema 1\n'
    printf 'release %s\n' "$RELEASE"
    printf 'arch %s\n' "$ARCH"
    # 构建机的 Darwin 主版本。Fink 的 darwin 虚拟包记的就是它，每个 .deb 都会
    # 带上 darwin (>= 这个值-1)。种子装到更老的系统上时，包能解开、文件也在，
    # 但任何新装都会被 dpkg 拒绝 —— 所以必须让安装器提前知道。
    printf 'darwin %s\n' "$(uname -r | cut -d. -f1)"
    printf 'seed seed.tar.gz\n'
    printf 'size %s\n' "$SIZE"
    printf 'sha256 %s\n' "$SHA"
    if [ -n "$URL" ]; then
        printf 'url %s\n' "$URL"
    fi
} > "$MANIFEST" || die "cannot write $MANIFEST"

printf 'seed     %s\n' "$SEED"
printf 'manifest %s\n' "$MANIFEST"
printf 'size     %s bytes\n' "$SIZE"
printf 'sha256   %s\n' "$SHA"

# 没给 --url 时清单里没有下载地址，安装器会回落到 $FINX_SEED_DOMAIN/<seed>。
# 那个回落是为自建镜像准备的；发布到 GitHub Release 时它指向错的地方，而
# 错误方式很安静 —— 清单探得到、种子下不来。实测踩过一次（seed-21）。
if [ -z "$URL" ]; then
    printf '\n'
    printf 'NOTE: no --url given, so the manifest has no download address.\n'
    printf '      The installer will fall back to $FINX_SEED_DOMAIN/<seed>:\n'
    printf '        %s\n' "${FINX_SEED_DOMAIN:-https://finx.sh/finx/seed}/seed.tar.gz"
    printf '      That is right for a self-hosted mirror. Publishing this seed as\n'
    printf '      a GitHub release needs --url <asset URL>, or it will be found\n'
    printf '      and then fail to download.\n'
fi
