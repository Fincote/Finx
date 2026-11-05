## 🧩 Finx

面向 macOS 的源码构建包管理器，建立在 `dpkg` / `apt` 体系之上。

[English](./README.md) · **简体中文**

> **正在开发中。** 接口与行为可能随时调整，不作预先通知。

## 🧩 官方网站

[finx.sh](https://finx.sh)

## 🧩 关于 Finx

**Finx** 是 **Fink** 的延续。Fink 是 macOS 上老牌的包管理器，借助 `dpkg` 维护自己的一套目录层级：下载原始源码，按需打补丁，为 Darwin 配置好，然后编译并安装。包描述——要构建什么、打哪些补丁、产物依赖什么——与代码分开维护，各自独立更新。

名字里的 `x` 取 **扩展** 之意。`dpkg` / `apt` 的依赖求解与副作用控制，至今仍强过大多数现代包管理器的做法，所以 Finx 保留这个内核，而不是换掉它。要扩展的是它周围的一切：安装前缀、文档，以及那些让 Fink 变得难以维护的地方。

## 🧩 为什么选择 Finx

1. **真有依赖求解。** `Depends`、`Conflicts`、`Provides`、虚拟包、`shlibs` 符号依赖，都由包管理器计算，而不是靠「先装这个再装那个」的约定。
2. **副作用可控。** `conffiles` 让你改过的配置在升级时不被覆盖；`preinst`、`postinst`、`prerm`、`postrm` 四个维护者脚本，逐一定义每一步该做什么。
3. **落地前先求解。** 安装前会算出「为了装这批包，需要临时卸掉谁」，而不是装到一半才发现冲突。
4. **单一规范前缀。** 一切都装在 `/opt/finx` 之下。过去按 macOS 版本在 `/sw` 与 `/opt/sw` 之间分叉的做法已经取消。
5. **源码与二进制双分发。** 有预编译的 `.deb` 就下，没有就从源码编；两者走同一条安装路径。
6. **只用 Perl 与 Shell。** 没有编译型依赖，读代码不必先配好工具链。
7. **锁是真锁。** 先抢 `dpkg` 数据库锁再 `exec`，锁随子进程继承，并发操作不会互相踩。
8. **装包需要 root，与 MacPorts 一样。** `sudo` 由 `finx` 自己调用；前缀始终归 root 所有，一份系统级二进制分发供所有用户使用。

## 🧩 支持的 macOS 版本

当前发行版树为 `10.9-libcxx`，覆盖 **macOS 10.9 及以上**，Intel 与 Apple 芯片均在支持范围内。

## 🧩 最新版本

`1.0.0-beta1` —— 首个公开测试版。二进制包分发通道尚未接通，种子之外的包
都要从源码构建；详见该版本的 Release 说明。

## 🧩 安装 Finx

Finx 的起点是宿主的 C 编译器：先把一个 `dpkg` 编译到临时脚手架里，再用这个 `dpkg` 把基础包装进 `/opt/finx`，最后删掉脚手架。

**环境要求：** macOS 10.9+、Xcode Command Line Tools、`/usr/bin/perl`（macOS 自带）。

```bash
xcode-select --install
sudo xcodebuild -license
```

然后在代码副本里执行：

```bash
cd finx
./bootstrap
```

`./bootstrap` 是交互式的：会问如何获取 root、装到哪里，以及几个配置问题。想跳过前缀那个问题，就把它作为第一个参数传入：

```bash
./bootstrap /opt/finx
```

注意二进制分发只在 Finx 装在 `/opt/finx` 时可用，因为 `.deb` 里的路径是构建时写死的。

装完之后：

```bash
. /opt/finx/bin/init.sh
```

安装器不会改你的 shell 启动文件。它会把需要执行的那一行打印出来，想让每个新终端都能用 `finx`，自己跑一次：

```bash
echo 'test -r /opt/finx/bin/init.sh && . /opt/finx/bin/init.sh' >> ~/.zprofile
```

（zsh 读 `~/.zprofile`；bash 读 `~/.bash_profile`，没有这个文件时读 `~/.profile`；csh/tcsh 读 `~/.login`。）

## 🧩 使用 Finx

```bash
finx install wget       # 安装
finx list               # 列出可用软件包
finx describe wget      # 查看包描述
finx remove wget        # 卸载，保留配置文件
finx purge wget         # 卸载，配置文件一并删除
finx selfupdate         # 更新包管理器自身
finx update-all         # 更新全部已安装包
```

装包操作需要 root；`sudo` 由 `finx` 自己调用，不必手动加。

完整命令表见 `USAGE`。构建产物不会自动清理 —— 用 `finx cleanup` 清掉源码 tarball、`.deb` 与陈旧构建锁。

## 🧩 与 Fink 的关系

| | Fink | Finx |
| --- | --- | --- |
| 安装前缀 | `/sw`，后来 `/opt/sw` | `/opt/finx` |
| 包管理内核 | `dpkg` / `apt` | `dpkg` / `apt`（不变） |
| 实现语言 | Perl 与 Shell | Perl 与 Shell（不变） |
| 发行版树 | 每个 macOS 版本一棵 | 不变，当前为 `10.9-libcxx` |
| 文档 | 分散，滞后于发布 | 统一到 `docs/` |
| 安装器 | 只能源码自举 | 二进制种子安装器（开发中） |

命令名仍是 `finx`，包名也未改动。改名会让现存的所有包描述失效，却换不来任何功能上的好处。

## 🧩 面向开发者

```bash
make test               # 完整性检查 + 全部测试
make format             # 缩进检查（Perl 用 tab，shell 用 4 空格）
./inject.pl /opt/finx   # 把工作副本装进已有安装
```

- [`docs/TECHNICAL-GUIDE.md`](./docs/TECHNICAL-GUIDE.md) —— 自举链路、装包流水线与 `dpkg` 定制。
- [`AGENTS.md`](./AGENTS.md) —— 改这棵树时要遵守的约定，对人和对 agent 都适用。
- [`STYLE`](./STYLE) —— 最初的代码风格指南。
- [`INSTALL`](./INSTALL) —— 详细的安装流程。

## 🧩 许可证

**这个项目不是单一许可，是两段拼起来的。**

- 从 Fink 继承的文件保持 **`GPL-2.0-or-later`** —— 这是 Fink 作者给的授权，
  我们无权收窄。
- 我们自己写的文件（安装器、`scripts/`、文档）采用 **`GPL-2.0-only`**。

合在一起分发时，整体只能是 **GPL 第二版**：两段授权唯一都能满足的交集就是它。

看文件头就能判断属于哪一段，不必查表。上游 GPL 全文见 [`COPYING`](./COPYING)，
范围说明与判定方法见 [`LICENSE`](./LICENSE)。两份文件都有中文参考译本
（[`COPYING-zh`](./COPYING-zh)、[`LICENSE-zh`](./LICENSE-zh)），法律效力仍以英文原文为准。
