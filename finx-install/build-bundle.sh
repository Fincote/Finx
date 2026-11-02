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
# finx-install/build-bundle.sh - 把模块化安装器打包成可直接 pipe 的单文件
#
# install.sh.in + lib/*.sh 是唯一事实来源；install.sh 是产物。
#
# 产物必须叫 install.sh、必须提交进仓库：设计目标是让用户直接
#   /bin/bash -c "$(curl -fsSL .../finx-install/install.sh)"
# 而管道里只能拿到一个文件，也不会执行 npm 式的安装步骤。源文件名以 .in 结尾，
# 与仓库里 finx.info.in / Fink.pm.in / pager.in 的约定一致 —— 看到 .in 就知道
# 它不是给人执行的。
#
# 用法：
#   ./finx-install/build-bundle.sh          重新生成 install.sh
#   ./finx-install/build-bundle.sh --check  只校验产物是否与源同步（CI 用）

set -u
set -o pipefail

FINX_HOME=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
SRC=$FINX_HOME/install.sh.in
OUT=$FINX_HOME/install.sh

emit() {
    printf '#!/bin/bash\n'
    printf '#\n'
    printf '# finx-install/install.sh - 从零安装 Finx\n'
    printf '#\n'
    printf '# 本文件由 finx-install/build-bundle.sh 生成，请勿直接编辑。\n'
    printf '# 唯一事实来源：finx-install/install.sh.in 与 finx-install/lib/*.sh\n'
    printf '#\n'
    printf '# 用法：/bin/bash -c "$(curl -fsSL <本文件的地址>)" -- [选项]\n'
    printf '#\n'
    printf '\n'
    printf 'FINX_BUNDLED=1\n'
    printf 'set -u\n'
    printf 'set -o pipefail\n'

    for module in common detect manifest extract source; do
        printf '\n# ======== lib/%s.sh ========\n' "$module"
        cat "$FINX_HOME/lib/$module.sh" || return 1
    done

    printf '\n# ======== install.sh.in ========\n'
    # 从 bundle:body 标记之后开始取，跳过头部注释、set 与 lib 加载段
    awk 'emit_now { print } /^# >>> bundle:body$/ { emit_now = 1 }' "$SRC"
}

if [ "${1:-}" = "--check" ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/finx-bundle.XXXXXX") || exit 1
    emit > "$tmp" || { rm -f "$tmp"; exit 1; }
    if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
        rm -f "$tmp"
        printf 'install.sh is up to date\n'
        exit 0
    fi
    rm -f "$tmp"
    printf 'ERROR: finx-install/install.sh is stale; run finx-install/build-bundle.sh\n' >&2
    exit 1
fi

case ${1:-} in
    '') ;;
    -h|--help)
        sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        printf 'ERROR: unknown option: %s\n' "$1" >&2
        exit 1
        ;;
esac

tmp=$OUT.tmp
emit > "$tmp" || { rm -f "$tmp"; exit 1; }
chmod 755 "$tmp" || { rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$OUT" || exit 1
printf 'wrote %s\n' "$OUT"
