# base-files（内置）

`base-files` 是 Fink 的「目录基础设施」包，`Essential: yes`。它提供的东西全都
在一次全新安装里最先用上，却一直不在本仓库：

- `bin/init.sh`、`bin/init.csh` —— 用户要 `source` 的那个脚本
- `bin/pager`、`bin/editor`
- `share/base-files/dir-base`
- `bin`、`etc`、`var/lib/dpkg` 那套目录骨架

在此之前，仓库里有 11 处引用 `$prefix/bin/init.sh`，零处生成它的代码 —— 它来自
SourceForge 上的 `fink/base-files-1.9.19.tar.gz`。那个地址在本机已经 404。

## 来源

上游是 `https://github.com/fink/base-files`，取的是 `release_1_9_19` 标签，
与 [`10.9-libcxx/base-files.info`](../10.9-libcxx/base-files.info) 里 pin 的
`Version: 1.9.19` 对应。许可证沿用上游的 GPL v2（见 [COPYING](./COPYING)）。

## 相对上游改了什么

只有两处，都是为了与本仓库的约定对齐：

1. `setup.sh` / `install.sh` 的用法示例里 `/sw` 改成 `/opt/finx`（纯提示文字）。
2. 缩进由 2 空格改为 4 空格，与 `scripts/format_check.pl` 的 shell 规则一致。

没有改行为。`setup.sh` 和 `install.sh` 仍然只接受一个前缀参数，`init.sh.in` 里的
`BASEPATH` 占位符仍由 `setup.sh` 在编译阶段替换 —— 所以这几个文件是**前缀无关**的，
`/opt/finx` 是从 `%p` 传进来的，不是写死的。

## 为什么要有 pack.sh

Fink 的 `find_tarball()` 先搜 `$basepath/src`，找到就不下载。所以只要在装包之前
把 tar 放进 `<prefix>/src`，`fink install base-files` 就完全不联网。
[`pack.sh`](./pack.sh) 负责生成它，`Bootstrap::pack_included_sources` 在
`bootstrap2` 里调用。

难点在于 `.info` 里的 `Source-MD5` 是写死的，而 tar 是在用户机器上现场生成的：
字节只要有一点差异，Fink 就会认定下载被篡改并停下来问人。所以 `pack.sh` 把一切
随机器变化的量都抹掉（mtime、uid/gid、属主名、tar 格式、成员顺序、gzip 头），
细节写在脚本头部注释里。

跨 `bsdtar` 版本仍可能有差异。那种情况由 `make sources_check` 当场抓住，而不是
留到 bootstrap 跑到一半。改了 `base-files/` 里的任何载荷文件之后：

```
./base-files/pack.sh --update      # 重新登记 MD5
make sources_check                 # 确认可复现
```

## 还没做的

[`dpkg-base-files`](../10.9-libcxx/dpkg-base-files.info) 同样是外部 tarball
（`fink/dpkg-base-files-0.4.tar.gz`）。它不阻塞「系统怎么跑起来」这个问题 ——
它提供的是 `.la` 文件清理的 triggers —— 但用的是同一套机制，可以照此办理。
