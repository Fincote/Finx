#!/bin/sh
#
# pack.sh - 打 base-files 的载荷 tar
#
# base-files 的源码原先只在 SourceForge 上（`mirror:custom:fink/%n-%v.tar.gz`），
# 而这台机器上那个地址已经 404。源码现由本仓库维护，`bootstrap` 在装包之前
# 就地打出 tar 放进 <prefix>/src，`fink install base-files` 便不再需要联网
# —— Fink 的 find_tarball 会先搜 $basepath/src，找到就不下载。
#
# 用法：
#   ./base-files/pack.sh <destdir>   生成 <destdir>/base-files-<version>.tar.gz
#   ./base-files/pack.sh --md5       打印本机产物的 MD5
#   ./base-files/pack.sh --check     校验本机产物与 .info 里登记的 MD5 一致
#   ./base-files/pack.sh --update    把本机产物的 MD5 写回 .info
#
# 为什么必须确定：.info 里的 Source-MD5 是写死的，而 tar 在每台机器上重新生成。
# 只要字节有任何差异，Fink 就会认为下载被篡改并停下来问用户。所以打包要抹掉
# 一切随机器变化的量：
#
#   mtime      每个文件先 touch 到固定时刻；touch -t 按本地时区解释，
#              所以 TZ 必须钉成 UTC，否则 epoch 随机器时区漂移
#   uid/gid    用 --uid/--gid 归零，不依赖构建者是谁
#   uname/gname 同理，用 root/wheel
#   格式       --format=ustar，不用 pax，pax 会写入额外的扩展头
#   成员顺序   显式列出文件名，不靠目录遍历的顺序
#   gzip       -n，不写入原始文件名与时间戳
#   AppleDouble COPYFILE_DISABLE=1，否则 macOS 会给带扩展属性的文件加 ._ 成员
#
# 跨 bsdtar 版本仍可能有差异。那种情况下 --check 会当场失败并指出该跑 --update，
# 而不是等 bootstrap 到一半才发现 Fink 在问「校验和不符」。

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
PACKCONF="$REPO_ROOT/base-files/pack.conf"
# 这份 .info 只在仓库里存在。载荷 tar 解出来的树没有 10.9-libcxx/，
# 而 fink 包的 CompileScript 会跑 make test —— 所以它是可选的交叉校验对象。
INFO="$REPO_ROOT/10.9-libcxx/base-files.info"

# 归档成员：与上游 base-files/inject.pl 的 $packagefiles 一致。
# 顺序即 tar 里的顺序，改动它会改变 MD5。
FILES="COPYING README NEWS dir-base editor.in init.csh.in init.sh.in install.sh pager.in setup.sh"

# 固定时间戳。选 2020-01-01，比任何一个文件的实际 mtime 都新，便于辨认。
STAMP=202001010000

die() {
    printf 'pack.sh: %s\n' "$*" >&2
    exit 1
}

# 版本与期望校验和都从 pack.conf 读。它随载荷一起发布，所以在一棵只有
# MANIFEST 里那些文件的树里也读得到 —— 这一点是硬要求，见 pack.conf 的注释。
[ -f "$PACKCONF" ] || die "can't find $PACKCONF"
PUBSPEC_VERSION=$(sed -n 's/^version[[:space:]]*//p' "$PACKCONF" | head -1)
EXPECTED_MD5=$(sed -n 's/^source-md5[[:space:]]*//p' "$PACKCONF" | head -1)
[ -n "$PUBSPEC_VERSION" ] || die "can't read version from $PACKCONF"
[ -n "$EXPECTED_MD5" ] || die "can't read source-md5 from $PACKCONF"
TARBALL="base-files-$PUBSPEC_VERSION.tar.gz"

# 打一次包，参数是输出目录。输出文件的路径回显到 stdout。
build() {
    outdir=$1
    [ -d "$outdir" ] || mkdir -p "$outdir" || die "can't create $outdir"

    stage=$(mktemp -d "${TMPDIR:-/tmp}/base-files-pack.XXXXXX") || die "mktemp failed"
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" EXIT INT TERM

    for f in $FILES; do
        [ -f "$REPO_ROOT/base-files/$f" ] || die "missing source file: base-files/$f"
        cp "$REPO_ROOT/base-files/$f" "$stage/$f" || die "can't copy $f"
        # TZ=UTC 是关键：touch -t 解析本地时间，不钉死时区 epoch 就会漂移。
        TZ=UTC touch -t "$STAMP" "$stage/$f" || die "can't set mtime on $f"
    done

    # 成员名要扁平（无顶层的 base-files-<ver>/ 目录）：Fink 的 phase_unpack
    # 会先 mkdir 并 chdir 到 buildpath/<fullname>，再就地解包。
    ( cd "$stage" \
        && COPYFILE_DISABLE=1 TZ=UTC tar \
            --format=ustar \
            --uid 0 --gid 0 --uname root --gname wheel \
            -cf "$outdir/$TARBALL.tmp" $FILES ) \
        || die "tar failed"

    gzip -9n -c "$outdir/$TARBALL.tmp" > "$outdir/$TARBALL" || die "gzip failed"
    rm -f "$outdir/$TARBALL.tmp"

    rm -rf "$stage"
    trap - EXIT INT TERM

    printf '%s\n' "$outdir/$TARBALL"
}

md5_of() {
    if command -v md5 >/dev/null 2>&1; then
        md5 -q "$1"
    else
        openssl dgst -md5 -r "$1" | cut -d' ' -f1
    fi
}

case "${1:-}" in
    ''|-h|--help)
        sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
    --md5)
        work=$(mktemp -d "${TMPDIR:-/tmp}/base-files-pack.XXXXXX") || die "mktemp failed"
        path=$(build "$work") || exit 1
        md5_of "$path"
        rm -rf "$work"
        ;;
    --check)
        work=$(mktemp -d "${TMPDIR:-/tmp}/base-files-pack.XXXXXX") || die "mktemp failed"
        path=$(build "$work") || exit 1
        got=$(md5_of "$path")
        rm -rf "$work"

        if [ "$EXPECTED_MD5" != "$got" ]; then
            printf 'FAILED: %s is not reproducible on this machine\n' "$TARBALL" >&2
            printf '        recorded in base-files/pack.conf: %s\n' "$EXPECTED_MD5" >&2
            printf '        produced here:                    %s\n' "$got" >&2
            printf '        Fink would reject the local tarball and ask the user.\n' >&2
            printf '        If the change is intentional (or this tar writes different\n' >&2
            printf '        headers), run ./base-files/pack.sh --update.\n' >&2
            exit 1
        fi

        # 仓库里还要求 .info 与 pack.conf 一致。载荷树里没有那份 .info，
        # 于是这一半静默跳过 —— 那一趟只能验可复现性，验不了两处是否同步。
        if [ -f "$INFO" ]; then
            info_md5=$(sed -n 's/^Source-MD5:[[:space:]]*//p' "$INFO" | head -1)
            if [ "$info_md5" != "$got" ]; then
                printf 'FAILED: 10.9-libcxx/base-files.info is out of sync\n' >&2
                printf '        .info says:        %s\n' "$info_md5" >&2
                printf '        pack.conf says:    %s\n' "$got" >&2
                printf '        run ./base-files/pack.sh --update\n' >&2
                exit 1
            fi
        fi

        printf 'base-files tarball OK (%s)\n' "$got"
        ;;
    --update)
        work=$(mktemp -d "${TMPDIR:-/tmp}/base-files-pack.XXXXXX") || die "mktemp failed"
        path=$(build "$work") || exit 1
        got=$(md5_of "$path")
        rm -rf "$work"
        sed -i '' -e "s|^source-md5 .*|source-md5 $got|" "$PACKCONF" \
            || die "can't update $PACKCONF"
        # .info 只在仓库里存在；载荷树里跳过。
        if [ -f "$INFO" ]; then
            sed -i '' -e "s|^Source-MD5:.*|Source-MD5: $got|" "$INFO" \
                || die "can't update $INFO"
        fi
        printf 'source-md5 updated to %s\n' "$got"
        ;;
    -*)
        die "unknown option: $1"
        ;;
    *)
        build "$1"
        ;;
esac
