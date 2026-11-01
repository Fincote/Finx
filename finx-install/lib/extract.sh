# shellcheck shell=bash
#
# 落盘与收尾：解包、修权限、ad-hoc 重签名、写配置、重建索引。
# 由 install.sh 以 . 方式加载，不单独执行。

extract_seed() {
    archive=$1
    target=$2

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would extract $archive into $target"
        return 0
    fi

    [ -f "$archive" ] || die "seed archive missing: $archive"
    [ -d "$target" ] || die "target directory missing: $target"

    tar -xzf "$archive" -C "$target" || die "failed to extract $archive"
}

# 种子里的文件在打包时已是 root 所有；以非 root 安装时只修目录权限即可。
fix_permissions() {
    target=$1

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would normalize ownership and modes under $target"
        return 0
    fi

    if [ "$(id -u)" -eq 0 ]; then
        for sub in bin sbin lib etc var/lib/dpkg; do
            [ -e "$target/$sub" ] && chown -R root:wheel "$target/$sub" 2>/dev/null
        done
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

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would ad-hoc re-sign Mach-O files under $target"
        return 0
    fi

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
write_config() {
    target=$1
    conf=$target/etc/fink.conf

    if [ -e "$conf" ]; then
        info "keeping existing $conf"
        return 0
    fi

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "would write $conf"
        return 0
    fi

    mkdir -p "$target/etc" || die "cannot create $target/etc"
    cat > "$conf" <<EOF
# Finx configuration, created by finx-install
# 其余字段（Trees / Distribution / SelfUpdateTrees）由 fink configure 补全。
Basepath: $target
EOF
}

run_scanpackages() {
    target=$1

    if [ ! -x "$target/bin/fink" ]; then
        warn "this seed has no $target/bin/fink; skipping the package index rebuild"
        return 0
    fi

    run "$target/bin/fink" scanpackages || warn "fink scanpackages failed; run it manually later"
    return 0
}
