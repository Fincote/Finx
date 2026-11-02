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
# 注意：这一段在**被 source 时**求值，而 detect_host 要到 main 里才跑。
# 所以 Darwin 版本不能读 $HOST_DARWIN_MAJOR（那时还是空），就地取 uname。
_finx_darwin=$(uname -r 2>/dev/null | cut -d. -f1)
case $_finx_darwin in
    ''|*[!0-9]*) _finx_darwin=0 ;;
esac

if [ -n "${FINX_DEFAULT_MANIFEST_URL:-}" ]; then
    DEFAULT_MANIFEST_URL=$FINX_DEFAULT_MANIFEST_URL
elif [ -n "${FINX_INDEX_DOMAIN_GIVEN:-}" ]; then
    DEFAULT_MANIFEST_URL=$FINX_INDEX_DOMAIN/manifest
else
    # 每个 macOS 大版本一份种子（darwin 依赖是按构建记录的，见 docs/MIRRORS.md
    # 三点六），所以默认地址要带上本机的 Darwin 主版本。
    #
    #   releases/download/seed-24/manifest     macOS 15
    #   releases/download/seed-21/manifest     macOS 12
    #
    # URL 里带 arch 与 darwin，是为了让缓存与 CDN 自然分开，也便于人工核对。
    DEFAULT_MANIFEST_URL=https://github.com/Fincote/Finx/releases/download/\
seed-$_finx_darwin/manifest
fi

# 只探存在性，不下载全文。用于决定走种子还是走源码。
#
# 返回值必须分三种，不能只有「行 / 不行」：
#
#   0  存在
#   1  确定不存在（服务端明确回了 4xx/5xx）
#   2  探不出来（连不上、超时、DNS 挂了）
#
# 为什么这点很重要：1 意味着「还没发布种子」，退回源码自举是合理的；2 意味着
# 「网络有问题」，而源码自举要去 SourceForge 下载 —— 网络有问题的地方，那条
# 路必然也走不通。把 2 当成 1，用户会看到它先说要编译十来分钟，再挂在下载上，
# 而真正该做的是检查代理或换镜像。
#
# 重试是必要的：实测同一条命令前一分钟能取到清单，下一分钟就 connect timeout。
probe_url() {
    url=$1
    tries=${FINX_PROBE_TRIES:-3}

    PROBE_ATTEMPTS=0
    total=$tries
    while [ "$tries" -gt 0 ]; do
        PROBE_ATTEMPTS=$((PROBE_ATTEMPTS + 1))
        attempt=$PROBE_ATTEMPTS
        [ "$attempt" -gt 1 ] && info "  no answer yet (attempt $attempt of $total)"

        code=$(curl -sS -o /dev/null -w '%{http_code}' -I \
            --connect-timeout 10 --max-time 20 --retry 1 "$url" 2>/dev/null) || code=000

        # HEAD 会被某些 CDN / 反爬层拒掉（403/405/501），而同一个地址用 GET
        # 取两个字节就正常。所以 HEAD 被拒时再问一次 GET。
        #
        # 000 不在此列：那表示连不上或超时，换 GET 只会把等待时间翻倍，
        # 而用户此时最需要的是尽快看到结论，不是再等一轮。
        case $code in
            403|405|429|501)
                code=$(curl -sS -o /dev/null -w '%{http_code}' -r 0-1 -L \
                    --connect-timeout 10 --max-time 20 --retry 1 "$url" 2>/dev/null) \
                    || code=000 ;;
        esac

        case $code in
            2??|3??) return 0 ;;
            # 只有这两个码能断定「确实没有」。403/429/451 是「被拦下了」，
            # 不是「不存在」—— 把它们当成不存在，用户就会被送去源码自举。
            404|410) return 1 ;;
        esac

        tries=$((tries - 1))
        [ "$tries" -gt 0 ] && sleep 2
    done
    return 2
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
        fetch_one "$MANIFEST_URL" "$MANIFEST_FILE" quiet \
            || die "$(t 'cannot download the seed manifest from' '下载种子清单失败：') $MANIFEST_URL"
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

    [ -n "$SEED_NAME" ] || die "$(t 'manifest has no seed entry' '清单里没有 seed 项')"
    case $SEED_NAME in
        */*) die "manifest seed name must not contain a path separator" ;;
    esac
    [ -n "$SEED_SHA256" ] || die "manifest has no sha256 entry"

    # 构建机的 darwin 主版本。老清单没有这一项，缺了就跳过检查（不能因此
    # 拒绝已经发布的旧种子）。
    SEED_DARWIN=$(manifest_field "$MANIFEST_FILE" darwin)
    case $SEED_SIZE in
        ''|*[!0-9]*) die "manifest size must be a byte count" ;;
    esac

    check_darwin_floor

    ARTIFACT_FILE=$FINX_TMP/$SEED_NAME
    info "$(t 'seed' '种子') $SEED_NAME ($(t 'release' '版本') ${SEED_RELEASE:-unknown}, $(human_size "$SEED_SIZE"))"
}

# 种子是在哪一代 Darwin 上构建的，就得在哪一代或更新的系统上装。
#
# 少了这个检查，用户会看到一个完全莫名其妙的失败：安装报告成功，文件都在，
# 但 sudo finx install <任何包> 都报
#
#   lzma depends on darwin (>= 25-1); however:
#     Version of darwin on system is 24.5.0-1.
#
# 真实踩过。早点说清楚，比让用户在装包时才撞墙好。
check_darwin_floor() {
    [ -n "${SEED_DARWIN:-}" ] || return 0
    case $SEED_DARWIN in
        ''|*[!0-9]*) return 0 ;;
    esac
    host=$(uname -r | cut -d. -f1)
    case $host in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$host" -ge "$SEED_DARWIN" ] && return 0

    msg=$(t "this seed was built on a newer macOS (Darwin $SEED_DARWIN); this system is Darwin $host" \
            "这个种子是在更新的 macOS 上构建的（Darwin $SEED_DARWIN），本机是 Darwin $host")
    die "$msg"
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
    # 第三个参数：quiet 表示文件很小（清单），不要画进度。
    quiet=${3:-}

    info "GET $url"

    # 进度显示分两档：
    #   quiet       -sS，只留真正的错误。清单就两百字节，画个进度表很荒唐
    #   其余        --progress-bar（即 curl -#），一条随宽度更新的进度条，
    #               不刷行，比默认那张会重画整屏的表干净得多
    if [ -n "$quiet" ]; then
        progress_opts=(-sS)
    else
        progress_opts=(--progress-bar)
    fi

    # --speed-limit/--speed-time 是这里唯一一处「不限总时长、但要判死活」的开关：
    #
    #   --connect-timeout 只管握手；握手成功之后传输停滞，curl 会一直等下去。
    #   实测过一次种子下到 1.7 MB / 21 MB 就再也不动了，进程挂在那里无限期。
    #
    #   总时长上限会误伤慢速网络（1 KB/s 但一直在走是能装完的），所以不用
    #   --max-time；改用「连续 45 秒低于 4 KB/s 就判死」，判死之后靠 -C - 续传。
    stall=(-C - --speed-limit 4096 --speed-time 45)
    part=$dest.part
    if ! curl -fL "${progress_opts[@]}" --connect-timeout "$FINX_CONNECT_TIMEOUT" \
            --retry 3 --retry-delay 2 "${stall[@]}" -o "$part" "$url"; then
        # 退出码 33 是「服务器不支持续传」，此时从头再来一次
        rm -f "$part"
        curl -fL "${progress_opts[@]}" --connect-timeout "$FINX_CONNECT_TIMEOUT" \
            --retry 2 --retry-delay 2 --speed-limit 4096 --speed-time 45 \
            -o "$part" "$url" || {
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
        info "$(t 'using local artifact' '使用本地文件') $src"
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

    die "$(t 'all mirror(s) failed for' '所有镜像都下载失败：') $SEED_NAME"
}

# 体积与 SHA256 都核对；任何一项不符都中止，不做「警告后继续」。
verify_file() {
    file=$1
    want_sha=$2
    want_size=$3

    [ -f "$file" ] || die "$(t 'file is missing:' '缺少文件：') $file"

    got_size=$(file_size "$file")
    [ "$got_size" = "$want_size" ] \
        || die "$(t 'size mismatch for' '大小不符：') $SEED_NAME $(t '(expected, got)' '（期望，实际）') $want_size / $got_size"

    got_sha=$(sha256_of "$file")
    if [ "$(lower "$got_sha")" != "$(lower "$want_sha")" ]; then
        die "sha256 mismatch for $SEED_NAME: expected $want_sha, got $got_sha"
    fi
    info "sha256 ok"
}
