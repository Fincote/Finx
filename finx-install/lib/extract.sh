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

    # 解包之后、任何东西碰这棵树之前。越界链接本身不会伤人，危险的是顺着它去读
    # 或去写 —— 而下一步 resign_macho 就会走遍整棵树、run_scanpackages 会执行
    # 树里的 bin/finx。所以检查必须卡在这里，且失败时清空前缀：半装好的树比
    # 没装更危险。
    offending=$(offending_links "$target")
    if [ -n "$offending" ]; then
        find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        die "the seed contains $(printf '%s\n' "$offending" | wc -l | tr -d ' ') symbolic link(s) pointing outside $target:
$offending
       Only these locations are exempt: $FINX_LINK_EXEMPT
       Refusing this payload. Report it to whoever built the seed."
    fi
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
        if [ "${ZH:-0}" -eq 1 ]; then
            warn "非 root 运行；$target 仍归 $(id -un) 所有"
        else
            warn "not running as root; $target stays owned by $(id -un)"
        fi
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
    info "$(t 're-signed' '已重签') $signed $(t 'Mach-O file(s)' '个 Mach-O 文件')"
}

# 只在配置不存在时写：已装过的目录里那份可能有用户调整。
# 种子必须带齐「能装包」所需的东西。没有 dpkg 的种子解出来是个死目录：
# finx 起不来，用户还以为装成功了。
#
# 真实事故：bootstrap 第三阶段在 fink-mirrors 的 postinst 上中断，排在它后面
# 的 dpkg 与 tar 一个都没装，打出来的种子缺 bin/dpkg。安装器照常报「安装完成」。
# 查归档而不是查解出来的树：解完才发现就晚了一步，前缀里已经躺了半个安装，
# 下次再跑还会撞上 "does not look like a Finx installation"。
require_seed_payload() {
    archive=$1
    listing=$FINX_TMP/seed-members
    # 成员名可能带 ./ 前缀（`tar -C dir .` 会这样），也可能不带。先归一化再比，
    # 否则同一种归档换个打包方式就判定失败。
    /usr/bin/tar -tzf "$archive" 2>/dev/null | sed 's|^\./||' > "$listing" \
        || die "cannot list $archive"

    missing=""
    for f in bin/finx bin/dpkg bin/dpkg-deb; do
        grep -qxF "$f" "$listing" || missing="$missing $f"
    done
    [ -z "$missing" ] || die "the seed is incomplete, missing:$missing
       This seed cannot install anything. Rebuild it from a complete bootstrap
       (see scripts/make_seed.sh) or report the publishing side."
}

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
            && info "$(t 'tree' '目录') finx/$dist -> 10.9-libcxx" \
            || warn "could not create finx/$dist"
    fi
    if [ "$(readlink "$base/dists" 2>/dev/null)" != "$dist" ]; then
        rm -f "$base/dists"
        ln -s "$dist" "$base/dists" 2>/dev/null \
            && info "$(t 'tree' '目录') finx/dists -> $dist" \
            || warn "could not point finx/dists at $dist"
    fi
}

# 修复 bootstrap 时代留下的 alternatives 链接。
#
# 种子里 bin/lzdiff、bin/lzgrep 与它们两个 man 页是绝对链接，指向
# <prefix>/bootstrap/etc/alternatives/... —— 而 bootstrap/ 在收尾时被删掉了，
# 于是装完就是死链：`lzdiff --version` 报 No such file or directory。
#
# 数据库本身是好的（var/lib/dpkg/alternatives 里记的路径都指向前缀），缺的只是
# 主链接和 bin 下那条链接的内容。所以让 update-alternatives 照数据库自己重建，
# 比在安装器里硬编码 lzdiff 这些名字靠得住 —— 将来哪个包用了 alternatives 都
# 一并修好。这里也修得动已经发出去的种子，不必重打。
repair_alternatives() {
    target=$1
    admin=$target/var/lib/dpkg/alternatives
    tool=$target/bin/update-alternatives
    [ -x "$tool" ] || return 0
    [ -d "$admin" ] || return 0

    repaired=0
    for entry in "$admin"/*; do
        [ -f "$entry" ] || continue
        name=${entry##*/}
        # 数据库第一行是状态，第二行是主链接。构建机写的是绝对路径。
        link=$(sed -n '2p' "$entry")
        case $link in
            "$target"/*) ;;
            *)
                warn "$(t "alternatives: $name points at $link, outside $target; left alone" \
                         "alternatives: $name 指向 $link，不在 $target 里，未改动")"
                continue ;;
        esac
        # 链接还能用就别动：用户可能手工选过候选项，重装不该悄悄改回去。
        [ -e "$link" ] && continue

        mkdir -p "$target/var/log" 2>/dev/null
        # --admindir / --altdir / --log 三个都要显式给：这个二进制把
        # /opt/finx 编死在代码里，不覆盖就会去改真正的前缀，而不是 $target。
        if "$tool" --admindir "$admin" --altdir "$target/etc/alternatives" \
                --log "$target/var/log/alternatives.log" --auto "$name" \
                >/dev/null 2>&1; then
            repaired=$((repaired + 1))
        else
            warn "$(t "alternatives: could not rebuild the link for $name" \
                     "alternatives: 没能重建 $name 的链接")"
        fi
    done

    [ "$repaired" -eq 0 ] \
        || info "$(t 'rebuilt' '重建') $repaired $(t 'alternatives link(s)' '个 alternatives 链接')"
}

# 前缀落点策略。
#
# 沙箱外只认 /opt/finx。理由是硬的，不是偏好：
#
#   1. 二进制包不可重定位 —— dylib 的 install_name 与 dpkg 的 .list 都是绝对
#      路径，装到别处得到的是一棵跑不起来的树（见 docs/PREFIX.md）。
#   2. 安装器有两条会大量删改内容的路径：解包会覆盖同名文件，而符号链接围栏
#      失败时会清空前缀的顶层内容。这两条作用在 /opt/finx 上只是重装；作用在
#      /usr/local 上就是删掉整份 Homebrew，再 chown -R root:wheel 接管它。
#
# 判定按物理路径做。--prefix=/opt/../usr/local 在字符串上看着无害，实际落在
# /usr/local —— MacWave 4.3 修的就是这一类，他们的校验也没做归一化。
#
# 沙箱里不设这条：apply_test_root 已经确认过前缀在测试根之内，那里的
# 「前缀」是 $TEST_ROOT/opt/finx 这种路径。
enforce_prefix_policy() {
    case $PREFIX in
        /opt/finx) return 0 ;;
    esac

    if [ -n "${FINX_TEST:-}" ]; then
        return 0
    fi

    # 归一化之后再判一次：把 .. 与符号链接都折掉，让 /opt/../opt/finx 也算数。
    real=$(resolve_path "$PREFIX")
    case $real in
        /opt/finx) PREFIX=$real; return 0 ;;
    esac

    # 多行文案的续行一律顶格：缩进它们会被 format_check 当成语句缩进。
    die "$(t "the install prefix must be /opt/finx, not $real.
Binary packages carry absolute paths, so a tree installed anywhere else does
not run; and unpacking into a system directory would overwrite or delete what
is already there.
Remove --prefix to install to /opt/finx." \
     "安装前缀只能是 /opt/finx，不能是 $real。
二进制包写死了绝对路径，装到别处跑不起来；而解包进一个系统目录会覆盖、甚至
删掉里面原有的东西。
去掉 --prefix 即装到 /opt/finx。")"
}

write_config() {
    target=$1
    dist=$2
    conf=$target/etc/finx.conf

    if [ -e "$conf" ]; then
        info "$(t 'keeping existing' '保留已有的') $conf"
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
# 与 bootstrap 写的一致：包描述自带的镜像组优先，master 垫底。
# 见 bootstrap 里同一行的注释。
MirrorOrder: MasterLast
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
