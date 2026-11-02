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
# 落盘与收尾：解包、修权限、ad-hoc 重签名、写配置、重建索引。
# 由 install.sh 以 . 方式加载，不单独执行。

extract_seed() {
    archive=$1
    target=$2

    [ -f "$archive" ] || die "seed archive missing: $archive"
    [ -d "$target" ] || die "target directory missing: $target"

    tar -xzf "$archive" -C "$target" || die "failed to extract $archive"
}

# 前缀必须归 root 所有，不能 chown 给调用者。
#
# 两个理由，都不是风格问题：
#   1. 解决不了免密码 —— finx install 的 rootflag 是 1，只看 $>，与归属无关；
#   2. 会开提权口子 —— dpkg 以 root 执行 postinst，且 Fink 的 dpkg 打了
#      fink-bld_no_fakeroot 补丁用真 root。前缀一旦用户可写，$prefix/bin/dpkg
#      与 var/lib/dpkg/status 就成了用户可控的 root 输入。
#
# 因此以 root 安装时统一归一为 root:wheel；非 root 只可能发生在 FINX_TEST
# 沙箱或用户自己拥有的前缀里，此时不动归属。
fix_permissions() {
    target=$1

    if [ "$(id -u)" -eq 0 ]; then
        chown -R root:wheel "$target" 2>/dev/null \
            || warn "could not chown $target to root:wheel"
    else
        warn "not running as root; $target stays owned by $(id -un)"
    fi

    for dir in "$target" "$target/bin" "$target/sbin" "$target/lib" "$target/etc"; do
        [ -d "$dir" ] && chmod 755 "$dir"
    done
    return 0
}

is_macho() {
    magic=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case $magic in
        cffaedfe|cefaedfe|cafebabe|bebafeca) return 0 ;;
        *) return 1 ;;
    esac
}

# 改动过二进制的种子必须重签名：Apple 芯片拒跑签名失效的可执行文件。
resign_macho() {
    target=$1

    if ! have codesign; then
        warn "codesign not found; skipping ad-hoc re-signing"
        return 0
    fi

    signed=0
    for file in "$target"/bin/* "$target"/sbin/* "$target"/lib/*.dylib; do
        [ -f "$file" ] || continue
        is_macho "$file" || continue
        if codesign -f -s - "$file" >/dev/null 2>&1; then
            signed=$((signed + 1))
        fi
    done
    info "re-signed $signed Mach-O file(s)"
}

# 只在配置不存在时写：已装过的目录里那份可能有用户调整。
# 本机的 Distribution。bootstrap 就是这么推的：主版本号 + ".0"。
# macOS 15.5 得到 15.0 —— 与 bootstrap 打印的 "Distribution: 15.0" 一致。
host_distribution() {
    printf '%s.0\n' "$HOST_MACOS_MAJOR"
}

# 把种子里的树对齐到**本机**的 Distribution。
#
# 种子是在构建机上打的，那里 finx/<dist> 与 finx/dists 指向构建机的版本
# （例如 26.0）。装到另一台机器上，Fink 会去找 finx/<本机版本>，找不到就
# 无法定位包池。bootstrap 自己也是这么做的（bootstrap:685/690）：
#
#   finx/<distribution> -> <selfupdatetrees>     这里 selfupdatetrees 恒为 10.9-libcxx
#   finx/dists          -> <distribution>
#
# 所有 10.9 及以上的版本共用 10.9-libcxx 这一套布局，所以别名指向它就够了，
# 不需要为每个 macOS 版本重打一份种子。
align_trees() {
    target=$1
    dist=$2
    base=$target/finx
    [ -d "$base/10.9-libcxx" ] || return 0    # 不是标准布局，什么都不动

    if [ ! -e "$base/$dist" ]; then
        ln -s 10.9-libcxx "$base/$dist" 2>/dev/null \
            && info "tree finx/$dist -> 10.9-libcxx" \
            || warn "could not create finx/$dist"
    fi
    if [ "$(readlink "$base/dists" 2>/dev/null)" != "$dist" ]; then
        rm -f "$base/dists"
        ln -s "$dist" "$base/dists" 2>/dev/null \
            && info "tree finx/dists -> $dist" \
            || warn "could not point finx/dists at $dist"
    fi
}

write_config() {
    target=$1
    dist=$2
    conf=$target/etc/finx.conf

    if [ -e "$conf" ]; then
        info "keeping existing $conf"
        return 0
    fi

    # 字段与 bootstrap 写的那份一致（bootstrap:748-753）。少任何一个 finx 都
    # 起不来 —— 之前只写 Basepath，结果 Distribution not set，scanpackages
    # 直接失败，装完等于没用。
    rootmethod=sudo
    if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
        rootmethod=none
    fi

    mkdir -p "$target/etc" || die "cannot create $target/etc"
    cat > "$conf" <<EOF
# Finx configuration, created by finx-install
Basepath: $target
RootMethod: $rootmethod
Trees: local/main stable/main
Distribution: $dist
SelfUpdateTrees: 10.9-libcxx
EOF
}

run_scanpackages() {
    target=$1

    if [ ! -x "$target/bin/finx" ]; then
        warn "this seed has no $target/bin/finx; skipping the package index rebuild"
        return 0
    fi

    run "$target/bin/finx" scanpackages || warn "finx scanpackages failed; run it manually later"
    return 0
}
