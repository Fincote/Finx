#!/bin/sh

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
# payload_test.sh - 在「载荷树」里跑一遍 make test
#
# finx 这个包自己的 CompileScript（见 finx.info.in）就是：
#
#     ./pre-build-test.sh
#     make test PREFIX=%p ARCHITECTURE=%m DISTRIBUTION=@DISTRIBUTION@
#     ./setup.sh %p %m
#
# 而它执行时的工作目录，是 bootstrap 用 create_tarball 从 MANIFEST 打出来、
# 再由 dpkg 解开的那棵树。那棵树里**只有 MANIFEST 列出的文件**：
#
#   - 没有 10.9-libcxx/（被 MANIFEST.SKIP 的 `^10\.[^/]*/` 排除）
#   - 没有 mirror/
#   - 没有 finx-install/
#   - 没有 .git，因此也跑不了 git ls-files
#
# 于是任何「只在仓库里成立」的假设都会在自举走到装 finx 这一步时炸掉，而
# 本地 `make test` 是绿的。这个目标就是为这类错误准备的：它重现那棵树，
# 在里面原样跑一遍 make test。
#
# 真实事故：base-files 的版本与校验和一度只写在 10.9-libcxx/base-files.info
# 里，`make sources_check` 于是读不到文件，bootstrap 死在 phase 3。
#
# 用法：
#   scripts/payload_test.sh
#   make payload_test

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$REPO_ROOT" || exit 1

ARCH=${FINX_ARCH:-x86_64}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/finx-payload.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

# 按 MANIFEST 重建那棵树。cp -p 保留权限：setup.sh 与 install.sh 需要可执行位。
sed -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' MANIFEST \
    | while IFS= read -r item; do
        [ -f "$item" ] || continue
        mkdir -p "$WORK/$(dirname "$item")"
        cp -p "$item" "$WORK/$item"
    done

# 前提条件：.git 与 10.9-libcxx 确实不在里面。少了这两条断言，这个脚本
# 可能在树还没重现对的时候就报绿。
if [ -d "$WORK/.git" ]; then
    printf 'FAILED: payload tree unexpectedly contains .git\n' >&2
    exit 1
fi
if [ -e "$WORK/10.9-libcxx" ]; then
    printf 'FAILED: payload tree unexpectedly contains 10.9-libcxx\n' >&2
    exit 1
fi

if ! ( cd "$WORK" && make test ARCHITECTURE="$ARCH" ); then
    printf '\nFAILED: make test does not pass inside the payload tree.\n' >&2
    printf 'bootstrap runs exactly this from finx.info.in'"'"'s CompileScript,\n' >&2
    printf 'in a tree that only contains what MANIFEST lists.\n' >&2
    exit 1
fi

printf 'payload tree OK (make test passes with only MANIFEST files)\n'
