#!/bin/sh
#
# structure_test.sh - 交叉校验三份手写清单是否自洽
#
# Fink 把同一份事实抄了三个副本，全部手写，彼此没有任何校验：
#
#   MANIFEST                bootstrap 打载荷 tar 时用（Bootstrap::fink_packagefiles）
#   Bootstrap::check_files  自举前断言源码树完整
#   install.sh 的复制语句   真正装进前缀的东西，大量依赖 shell 通配符
#
# 三者不同步就会静默出错。readme.de.html 就是现成的例子：它在 git 里、会被
# install.sh 的 `readme.*.html` 装上、却不在 MANIFEST 里 —— 于是它从未进过
# 任何一个载荷包，而 `make test` 只报了一句"Not in MANIFEST"，没人看得出
# 这句话的含义是"德文 readme 从来没发出去过"。
#
# 本脚本不去解析 install.sh。它的写法是
#
#   for file in update-packages/* ; do install ... ; done
#
# 任何解析器与 shell 的实际行为都会在某处不一致，而不一致的那处正是 bug
# 藏身的地方。所以这里直接执行：分别在「只含 git 清单的树」和「只含 MANIFEST
# 的树」里各跑一遍 setup.sh + install.sh，比对两次的安装结果。
#
# 两棵树装出来的东西必须完全一致。这条断言同时覆盖了两个方向：
#   少了  → MANIFEST 漏登记（install.sh 会装，载荷 tar 里却没有）
#   多了  → MANIFEST 多登记，或 install.sh 读了目录里碰巧存在的东西
#
# 不在 git 工作区里运行时（例如从 tarball 解出来的树）跳过双树比对，只做静态检查。
#
# 用法：
#   scripts/structure_test.sh            校验，有问题退出 1
#   make structure                       同上
#
# 环境变量：
#   FINX_ARCH    安装时用的架构，默认跟随 uname -m

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$REPO_ROOT" || exit 1

ARCH=${FINX_ARCH:-}
if [ -z "$ARCH" ]; then
    case "$(uname -m)" in
        arm64|x86_64) ARCH=$(uname -m) ;;
        *) ARCH=$(uname -m) ;;
    esac
fi

# 前缀只用来生成脚本内容，不实际写入；install.sh 的目标目录由这里指定。
PREFIX=/opt/finx

WORK=$(mktemp -d "${TMPDIR:-/tmp}/finx-structure.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

FAIL=0
bad() {
    printf 'FAILED: %s\n' "$*"
    FAIL=1
}

# ---------------------------------------------------------------------------
# 1. 收集三份清单
# ---------------------------------------------------------------------------

sed -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' MANIFEST | sort -u > "$WORK/manifest"

# check_files 的 qw(...) 列表。整体读入再匹配，因为列表本身跨多行。
perl -0777 -ne 'if (/sub[ \t]+check_files\b.*?qw\(([^)]*)\)/s) {
        print "$_\n" for ($1 =~ /(\S+)/g);
    }' perlmod/Fink/Bootstrap.pm \
    | sort -u > "$WORK/check_files"

if [ ! -s "$WORK/manifest" ]; then
    bad "MANIFEST 是空的或读不到"
fi
if [ ! -s "$WORK/check_files" ]; then
    bad "没能从 perlmod/Fink/Bootstrap.pm 里取到 check_files 列表"
fi

# ---------------------------------------------------------------------------
# 2. 静态检查：清单里的每一条都得有出处
# ---------------------------------------------------------------------------

IN_GIT=0

if git rev-parse --git-dir >/dev/null 2>&1; then
    IN_GIT=1
    git ls-files | sort -u > "$WORK/tracked"

    # MANIFEST 只能登记仓库里真实存在的文件，否则打 tar 时会静默少文件
    # （fink_packagefiles 用 `-f` 过滤，不存在的条目就这么消失了）。
    comm -23 "$WORK/manifest" "$WORK/tracked" > "$WORK/phantoms"
    if [ -s "$WORK/phantoms" ]; then
        bad "MANIFEST 登记了仓库里不存在的文件（打 tar 时会被静默跳过）"
        sed 's/^/    /' "$WORK/phantoms"
    fi

    # check_files 的每一项都必须能从仓库里拿到。
    # 其中 perlmod/Fink、update 是目录，用「有没有下级文件」判定。
    : > "$WORK/cf_missing"
    while IFS= read -r entry; do
        if grep -qxF "$entry" "$WORK/tracked"; then
            continue
        fi
        if grep -q "^$(printf '%s' "$entry" | sed 's/[.[\*^$]/\\&/g')/" "$WORK/tracked"; then
            continue
        fi
        printf '%s\n' "$entry" >> "$WORK/cf_missing"
    done < "$WORK/check_files"

    if [ -s "$WORK/cf_missing" ]; then
        bad "check_files 要求的文件在仓库里不存在（自举会在这里 die）"
        sed 's/^/    /' "$WORK/cf_missing"
    fi
else
    printf 'NOTE: 不在 git 工作区里，跳过与 git 清单的比对\n'
fi

# ---------------------------------------------------------------------------
# 3. 动态检查：两棵树装出来的东西必须一致
# ---------------------------------------------------------------------------

if [ "$IN_GIT" -eq 1 ]; then
    # 只复制清单里列出的文件，且保留权限 —— setup.sh 与 install.sh 需要可执行位。
    build_tree() {
        list=$1
        dest=$2
        while IFS= read -r item; do
            [ -f "$item" ] || continue
            mkdir -p "$dest/$(dirname "$item")"
            cp -p "$item" "$dest/$item"
        done < "$list"
    }

    build_tree "$WORK/tracked" "$WORK/tree-git"
    build_tree "$WORK/manifest" "$WORK/tree-manifest"

    for tree in tree-git tree-manifest; do
        if ! ( cd "$WORK/$tree" \
                && ./setup.sh "$PREFIX" "$ARCH" > "$WORK/$tree.setup.log" 2>&1 \
                && ./install.sh "$WORK/$tree.prefix" "$ARCH" > "$WORK/$tree.install.log" 2>&1 )
        then
            bad "$tree 里 setup.sh + install.sh 失败，日志："
            sed 's/^/    /' "$WORK/$tree.setup.log" "$WORK/$tree.install.log" | tail -20
        fi
    done

    # 先比内容与符号链接目标。
    if ! diff -r "$WORK/tree-git.prefix" "$WORK/tree-manifest.prefix" \
            > "$WORK/diff.txt" 2>&1
    then
        bad "两棵树装出来的结果不同（MANIFEST 与实际安装不一致）"
        sed -e "s|$WORK/||g" "$WORK/diff.txt" | head -40 | sed 's/^/    /'
        if [ "$(wc -l < "$WORK/diff.txt" | tr -d ' ')" -gt 40 ]; then
            printf '    ……（差异过多，只显示前 40 行）\n'
        fi
    fi

    # 语义断言：可执行位的分布。这是唯一能抓到 -m 参数写错的地方 ——
    # 两棵树共用同一个 install.sh，所以「两棵树权限位相同」是恒真的，
    # 比它没有意义。少了可执行位等于装了个敲了就 command not found 的 fink。
    assert_perm() {  # $1=前缀 $2=子目录 $3=exec|noexec
        _prefix=$1
        _sub=$2
        [ -d "$_prefix/$_sub" ] || return 0
        if [ "$3" = exec ]; then
            find "$_prefix/$_sub" -mindepth 1 -type f ! -perm -111
        else
            find "$_prefix/$_sub" -mindepth 1 -type f -perm -111
        fi
    }

    for tree in tree-git tree-manifest; do
        prefix="$WORK/$tree.prefix"
        for sub in bin sbin; do
            offenders=$(assert_perm "$prefix" "$sub" exec)
            if [ -n "$offenders" ]; then
                bad "$tree：$sub/ 下有文件没有可执行位"
                printf '%s\n' "$offenders" | sed -e "s|^$prefix/|    |"
            fi
        done
        offenders=$(assert_perm "$prefix" lib/perl5 noexec)
        if [ -n "$offenders" ]; then
            bad "$tree：lib/perl5/ 下的模块带了可执行位"
            printf '%s\n' "$offenders" | sed -e "s|^$prefix/|    |"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 4. 结论
# ---------------------------------------------------------------------------

if [ "$FAIL" -ne 0 ]; then
    printf '\nstructure check FAILED\n'
    exit 1
fi

count_tracked=0
count_manifest=$(wc -l < "$WORK/manifest" | tr -d ' ')
count_check=$(wc -l < "$WORK/check_files" | tr -d ' ')
count_installed=0

if [ "$IN_GIT" -eq 1 ]; then
    count_tracked=$(wc -l < "$WORK/tracked" | tr -d ' ')
    count_installed=$(find "$WORK/tree-git.prefix" -mindepth 1 \
        \( -type f -o -type l \) | wc -l | tr -d ' ')
fi

printf 'structure OK (%s tracked, %s in MANIFEST, %s in check_files, %s installed)\n' \
    "$count_tracked" "$count_manifest" "$count_check" "$count_installed"
exit 0
