#!/bin/bash
#
# ci_bootstrap.sh - 在 CI 里跑一次完整的 ./bootstrap，失败可续传
#
# 这个脚本存在的唯一理由是：GitHub Actions 与 CircleCI 都要跑同一件事，
# 而那份逻辑（重试、清空、只认下载失败）不长但很细，抄两遍必然漂移。
# 上一轮就是例子 —— 重试循环写在 YAML 里，改了一次忘了 set +e，整段逻辑
# 静默失效，而日志看不出少了什么。
#
# 用 bash 而不是 /bin/sh：需要 PIPESTATUS。管道 `bootstrap | tee` 的 $? 是
# tee 的退出码，永远为 0，拿它判断成败会让重试逻辑形同虚设。POSIX sh 没有
# PIPESTATUS，所以这里不图省事。
#
# 用法：
#   scripts/ci_bootstrap.sh PREFIX [ATTEMPTS]
#
# 需要：能免密 sudo、在仓库根目录执行、stdin 可关闭。
#
# 三个设计要点，都是踩过的坑：
#
# 1. 用 `sudo ./bootstrap .sudo PREFIX` 而不是让它自己提权。
#    bootstrap:272 会把第一个以 "." 开头的参数当作 rootmethod，这正是它提权
#    重启自己时的写法；显式给出就不必依赖 stdin 的默认值。而它自己的提权分支
#    从 /dev/tty 读密码，CI 里没有终端。
#
# 2. stdin 重定向到 /dev/null。Fink::CLI 的每个提问读到 EOF 都返回空串，
#    configure() 一律取默认值 —— 这就是无人值守的机制，不需要改 Fink。
#
# 3. 重试是安全的，但**必须清空前缀**。tarball 落在 $PREFIX/src，
#    cmd_fetch_missing 会跳过已有的，所以每轮从断点继续；可如果不清掉其余
#    内容，下一轮 bootstrap 会发现 $PREFIX 里"已有安装"并自动跳到
#    $PREFIX2、$PREFIX3…… 那个前缀是废的：bindist_check_prefix 只认
#    /opt/finx，种子里的绝对路径也会错。实测第 4 轮就是这样装进了 /opt/finx2。

set -u

PREFIX=${1:-}
ATTEMPTS=${2:-5}

if [ -z "$PREFIX" ]; then
    printf 'usage: %s PREFIX [ATTEMPTS]\n' "$0" >&2
    exit 2
fi

case "$PREFIX" in
    /*) ;;
    *) printf 'FAILED: prefix must be absolute, got %s\n' "$PREFIX" >&2; exit 2 ;;
esac

LOG=${FINX_CI_BOOTSTRAP_LOG:-bootstrap.log}

if ! sudo -n true 2>/dev/null; then
    printf 'FAILED: passwordless sudo unavailable\n' >&2
    exit 1
fi

printf 'bootstrap into %s (log: %s)\n' "$PREFIX" "$LOG"

rc=1
n=1
while [ "$n" -le "$ATTEMPTS" ]; do
    printf '==== attempt %s of %s ====\n' "$n" "$ATTEMPTS"

    # 显式 set +e：调用方可能继承 -e（GitHub Actions 的 run: 默认就是 bash -e），
    # 那样 bootstrap 一失败整个脚本立刻退出，重试逻辑根本不会执行。
    set +e
    sudo ./bootstrap .sudo "$PREFIX" < /dev/null 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ]; then
        printf '==== attempt %s succeeded ====\n' "$n"
        break
    fi

    # 只在一轮里确实出现过下载失败时才重试。编译失败重试没用，
    # 只会把真正的错误埋进五份日志里。
    # 匹配的是失败行，不是「Downloading the file」——那行成功时也会出现。
    if ! tail -300 "$LOG" | grep -qE 'Downloading the file .* failed'; then
        printf '==== attempt %s failed and it was not a download problem; not retrying ====\n' "$n"
        break
    fi

    printf '==== attempt %s failed on a download; retrying ====\n' "$n"

    # 保留 src/（已下好的 tar 缓存），其余清空 —— 理由见文件头第 3 点。
    sudo find "$PREFIX" -mindepth 1 -maxdepth 1 \
        ! -name src -exec rm -rf {} + 2>/dev/null || true

    n=$((n + 1))
    sleep 5
done

printf -- '---- bootstrap exited %s ----\n' "$rc"
tail -40 "$LOG" 2>/dev/null

exit "$rc"
