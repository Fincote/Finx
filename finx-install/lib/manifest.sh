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
# 种子清单的解析、下载与校验。
#
# 清单是行取向的纯文本，故意不用 JSON：安装阶段不该依赖 jq，
# 而 awk 一行就能取到字段，签名与 diff 也都更方便。
#
#   schema  1
#   release 0.46.0
#   arch    arm64
#   seed    seed.tar.gz
#   size    12345678
#   sha256  <64 位十六进制>
#   url     https://host/a/seed.tar.gz
#   url     https://host/b/seed.tar.gz

# 默认种子位置。优先级：
#
#   --manifest-url / FINX_MANIFEST_URL   显式指定，最高
#   FINX_INDEX_DOMAIN                    用户给了域名，就拼 <域名>/manifest
#   GitHub Releases 上的 seed 标签        都不给时的默认，见下
#
# 为什么默认指向 Releases 而不是 finx.sh：`curl | bash` 的意义就是「不需要先
# 读文档、不需要设环境变量」。在自己的域名托管起来之前，Releases 是唯一一个
# 立刻可用的稳定地址；而 FINX_INDEX_DOMAIN 随时可以把它换掉。
if [ -n "${FINX_DEFAULT_MANIFEST_URL:-}" ]; then
    DEFAULT_MANIFEST_URL=$FINX_DEFAULT_MANIFEST_URL
elif [ -n "${FINX_INDEX_DOMAIN_GIVEN:-}" ]; then
    DEFAULT_MANIFEST_URL=$FINX_INDEX_DOMAIN/manifest
else
    DEFAULT_MANIFEST_URL=https://github.com/Fincote/Finx/releases/download/seed/manifest
fi

# 只探存在性，不下载全文。用于决定走种子还是走源码。
probe_url() {
    url=$1
    curl -fsI --connect-timeout 10 --max-time 20 "$url" >/dev/null 2>&1
}

# 解析清单，设置 MANIFEST_FILE / ARTIFACT_BASE / ARTIFACT_FILE /
# SEED_NAME / SEED_SIZE / SEED_SHA256 / SEED_RELEASE。
resolve_manifest() {
    ensure_tmp

    if [ -n "$SEED_DIR" ]; then
        [ -d "$SEED_DIR" ] || die "seed directory not found: $SEED_DIR"
        MANIFEST_FILE=$SEED_DIR/manifest
        ARTIFACT_BASE=$SEED_DIR
    else
        [ -n "$MANIFEST_URL" ] || die "no seed location given; use --seed-dir or --manifest-url"
        MANIFEST_FILE=$FINX_TMP/manifest
        ARTIFACT_BASE=""
        fetch_one "$MANIFEST_URL" "$MANIFEST_FILE" \
            || die "cannot download the seed manifest from $MANIFEST_URL"
    fi

    [ -f "$MANIFEST_FILE" ] || die "manifest not found: $MANIFEST_FILE"

    schema=$(manifest_field "$MANIFEST_FILE" schema)
    [ "$schema" = "1" ] || die "unsupported manifest schema: ${schema:-<missing>}"

    manifest_arch=$(manifest_field "$MANIFEST_FILE" arch)
    [ "$manifest_arch" = "$HOST_ARCH" ] \
        || die "seed is built for $manifest_arch but this host is $HOST_ARCH"

    SEED_RELEASE=$(manifest_field "$MANIFEST_FILE" release)
    SEED_NAME=$(manifest_field "$MANIFEST_FILE" seed)
    SEED_SIZE=$(manifest_field "$MANIFEST_FILE" size)
    SEED_SHA256=$(manifest_field "$MANIFEST_FILE" sha256)

    [ -n "$SEED_NAME" ] || die "manifest has no seed entry"
    case $SEED_NAME in
        */*) die "manifest seed name must not contain a path separator" ;;
    esac
    [ -n "$SEED_SHA256" ] || die "manifest has no sha256 entry"
    case $SEED_SIZE in
        ''|*[!0-9]*) die "manifest size must be a byte count" ;;
    esac

    ARTIFACT_FILE=$FINX_TMP/$SEED_NAME
    info "seed $SEED_NAME (release ${SEED_RELEASE:-unknown}, $(human_size "$SEED_SIZE"))"
}

manifest_field() {
    awk -v key="$2" '$1 == key { print $2; exit }' "$1"
}

manifest_urls() {
    awk '$1 == "url" { print $2 }' "$1"
}

# 下载单个 URL 到目标路径。先写 .part，成功后再改名，因此 -C - 续传是安全的。
fetch_one() {
    url=$1
    dest=$2

    info "GET $url"

    part=$dest.part
    if ! curl -fL --connect-timeout "$FINX_CONNECT_TIMEOUT" --retry 2 -C - -o "$part" "$url"; then
        # 退出码 33 是「服务器不支持续传」，此时从头再来一次
        rm -f "$part"
        curl -fL --connect-timeout "$FINX_CONNECT_TIMEOUT" -o "$part" "$url" || {
            rm -f "$part"
            return 1
        }
    fi
    mv -f "$part" "$dest" || return 1
    return 0
}

# 取得种子产物：本地目录直接拷贝，否则按清单里的 url 逐个尝试。
fetch_artifact() {
    if [ -n "$ARTIFACT_BASE" ]; then
        src=$ARTIFACT_BASE/$SEED_NAME
        [ -f "$src" ] || die "seed artifact not found: $src"
        info "using local artifact $src"
        run cp -f "$src" "$ARTIFACT_FILE"
        return 0
    fi

    manifest_urls "$MANIFEST_FILE" > "$FINX_TMP/urls"

    # 清单里没写 url 时，用 FINX_SEED_DOMAIN 拼一个。这样自建镜像只要设
    # 环境变量就能用，不必为每种布局各维护一份清单。
    if [ ! -s "$FINX_TMP/urls" ]; then
        printf '%s/%s\n' "$FINX_SEED_DOMAIN" "$SEED_NAME" > "$FINX_TMP/urls"
        info "manifest has no url entries; falling back to $FINX_SEED_DOMAIN"
    fi

    tried=0
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        tried=$((tried + 1))
        if fetch_one "$url" "$ARTIFACT_FILE"; then
            return 0
        fi
        warn "mirror failed: $url"
    done < "$FINX_TMP/urls"

    die "all $tried mirror(s) failed for $SEED_NAME"
}

# 体积与 SHA256 都核对；任何一项不符都中止，不做「警告后继续」。
verify_file() {
    file=$1
    want_sha=$2
    want_size=$3

    [ -f "$file" ] || die "artifact missing: $file"

    got_size=$(file_size "$file")
    [ "$got_size" = "$want_size" ] \
        || die "size mismatch for $SEED_NAME: expected $want_size bytes, got $got_size"

    got_sha=$(sha256_of "$file")
    if [ "$(lower "$got_sha")" != "$(lower "$want_sha")" ]; then
        die "sha256 mismatch for $SEED_NAME: expected $want_sha, got $got_sha"
    fi
    info "sha256 ok"
}
