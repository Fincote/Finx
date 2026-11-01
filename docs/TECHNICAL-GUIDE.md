# Finx 技术手册

> 目标：讲清「为什么这样设计」。文件在哪、归谁管，见 [CODE-MAP.md](./CODE-MAP.md)。
>
> 适用版本：`0.45.99.git`

## 目录

1. [安装体系现状](#一安装体系现状)
2. [fink 如何安装自己](#二fink-如何安装自己)
3. [装包流水线](#三装包流水线)
4. [依赖模型与一致性求解](#四依赖模型与一致性求解)
5. [dpkg 定制](#五dpkg-定制)
6. [锁与并发](#六锁与并发)
7. [网络与镜像](#七网络与镜像)
8. [面向用户的新安装器（设计）](#八面向用户的新安装器设计)
9. [测试](#九测试)
10. [已知问题与地雷](#十已知问题与地雷)

---

## 一、安装体系现状

### 1.1 从零开始的链路

用户手上只有宿主系统与网络，没有任何包管理器。唯一的支点是宿主的 C 编译器 ——
`dpkg` 不是被安装的，是被**编译**出来的。

```
macOS + Xcode CLT（cc / GNU make / tar / pod2man）+ /usr/bin/perl + 网络
        │
        │  用户手动下载 fink-<ver>.tar.gz  ← 唯一需要用户动手的下载
        ▼
   ./bootstrap                                          bootstrap:1
        │
        ├─① 下 tar-1.29 源码 → 宿主 cc 编译 → $prefix/bootstrap/bin/tar（gtar）
        ├─② 下 dpkg-1.19.7 源码 → 打 12 个补丁 → 宿主 cc 编译
        │     → $prefix/bootstrap/bin/{dpkg,dpkg-deb}      ← 系统第一次有包管理器
        ├─③ 用这个新 dpkg，把 15 个 Essential 包从源码编成 .deb 装进 $prefix
        └─④ rm -rf $prefix/bootstrap（一次性脚手架）
```

对应代码：

| 步骤 | 位置 | 说明 |
| --- | --- | --- |
| 选址与护栏 | [bootstrap:505](../bootstrap) | 禁止清单（`/usr`、`/usr/local`、`/opt/local`、`/opt/homebrew`）、整条路径必须 world-rx |
| 铺骨架 | [bootstrap:630](../bootstrap) | `etc etc/apt src fink/debs var/lib/dpkg var/lib/fink …` |
| 把自己变成包 | [create_tarball](../perlmod/Fink/Bootstrap.pm:792) | 按 `MANIFEST` 打 `$prefix/src/fink-<ver>.tar` |
| 写包描述 | [copy_description](../perlmod/Fink/Bootstrap.pm:858) | 填 MD5/SHA256，`Source` 指向刚打的 tar，追加 `NoSourceDirectory: true` |
| 阶段一 | [bootstrap1](../perlmod/Fink/Bootstrap.pm:492) | 只编 tar-bootstrap / dpkg-bootstrap，**绕过包管理**，落进 `$prefix/bootstrap` |
| 阶段二 | [bootstrap2](../perlmod/Fink/Bootstrap.pm:586) | 用目标 perl 重新 exec `bootstrap-phase2.pl`，首次走 `cmd_install` |
| 阶段三 | [bootstrap3](../perlmod/Fink/Bootstrap.pm:632) | 删掉脚手架 |
| 建索引 | [bootstrap:860](../bootstrap) | `fink scanpackages` 生成 `Packages.gz` |

### 1.2 为什么必须先造 tar 再造 dpkg

`dpkg-deb` 依赖 `tar`，而 macOS 自带 tar 在 10.9+ 的行为（`--format=gnu`、
`--warning=no-timestamp`）dpkg 不认。补丁里按 `uname` 分支改写 dpkg 对 tar 的调用
（见 [dpkg-bootstrap.info](../10.9-libcxx/dpkg-bootstrap.info)）：

```sh
if [ "%n" = "dpkg-bootstrap" ]; then
    if [[ $(uname -a | cut -d' ' -f3) > 12 ]]; then
        perl -pi -e 's,\"tar\",\"/usr/bin/tar\",g' dpkg-deb/build.c ...
        perl -pi -e 's,--format=gnu,--format=ustar,g' dpkg-deb/build.c
```

所以先编一个受控的 GNU tar，把 `tar` 的行为钉死，再编 dpkg。

### 1.3 五个脆弱点

| 脆弱点 | 触发条件 | 症状 | 现有兜底 |
| --- | --- | --- | --- |
| 源码托管方不可达 | SourceForge / ftpmirror.gnu.org 慢或挂 | ① ② 卡死或超时 | 无。`CustomMirror` 只在国内镜像里有冗余 |
| 工具链版本越界 | Xcode 超出 [bootstrap:343](../bootstrap) 的 min/max 表 | 直接 `die`，即使编译器完全可用 | 无。只能改代码 |
| 构建期工具缺失 | `pod2man` 不在或被改坏 | [pre-build-test.sh](../pre-build-test.sh:26) 拦下 | 会提示 `chmod a+x`，其余无 |
| 12 个补丁任一失败 | 上游源码变动或新编译器行为变化 | 自举中断 | 无。必须人工介入 |
| 系统 perl 被移除 | Apple 兑现移除 `/usr/bin/perl` | 入口脚本无法启动 | 无。这是 Fink 最致命的单点 |

这五点有一个共同性质：**全部失败在用户第一次接触产品的时刻**，而且没有降级路径。
这是第四节到第八节要解决的问题。

---

## 二、fink 如何安装自己

fink 对自己没有特殊待遇 —— 它把自己变成一个包，然后按普通包安装。

| 路径 | 入口 | 源码从哪来 | 是否经过 dpkg |
| --- | --- | --- | --- |
| 首装 | [bootstrap](../bootstrap) | 用户下载的 tarball，`MANIFEST` 本地打包 | 阶段一否，阶段二是 |
| 注入（开发者） | [inject.pl](../inject.pl) → [inject_package](../perlmod/Fink/Bootstrap.pm:282) | 当前工作副本 | 是 |
| 自更新 | [SelfUpdate::finish](../perlmod/Fink/SelfUpdate.pm:312) | 包描述里的 `Source`（发布 tarball） | 是 |

`inject_package` 的最后一步最能说明它的本质：

```perl
&execute("/usr/bin/perl $bpath/bin/fink install $package-$packageversion-$packagerevision")
```

**用旧 fink 装新 fink。** 三条路径共用同一套 `setup.sh` + `install.sh` + `dpkg-deb -b`。

因为 `fink` 声明了 `Essential: yes`，`selfupdate` 的
`cmd_install(list_essential_packages())` 天然会把它自己包含进去，不需要专门的
"升级自己"分支。

---

## 三、装包流水线

`fink install foo` → [real_install](../perlmod/Fink/Engine.pm:1730)：

```
解析参数 → 依赖求解 → 决定源码/二进制 → 对每个包跑 phase_*
```

`Fink::PkgVersion` 的阶段划分：

| 阶段 | 做什么 |
| --- | --- |
| `phase_fetch_deb` / `fetch_deb` | 二进制分发：`apt-get --print-uris` 拿 URL，自己下载 |
| `phase_fetch` | 源码：按 `Source` 走镜像下载，校验 MD5/SHA256 |
| `phase_unpack` / `phase_patch` | 解包、打补丁 |
| `phase_compile` | 跑 `CompileScript`（`%b` 是构建目录） |
| `phase_install` | 装进假根 `%i`，生成 `%d/DEBIAN` 控制文件 |
| `phase_build` | `dpkg-deb -b` 封包，强制 gzip 与 `LANG=C LC_ALL=C` |
| `phase_activate` | 一致性求解 → `dpkg -i *.deb` |
| `phase_deactivate` / `phase_purge` | `dpkg --remove` / `--purge`；批量走 `apt-get remove` |

字段与占位符（`%p` 前缀、`%b` 构建目录、`%i` 假根、`%d` DEBIAN 目录、`%n` 名、`%v` 版本、
`%m` 架构）由 `Fink::Services::expand_percent` 展开。

---

## 四、依赖模型与一致性求解

包描述里的依赖字段：

| 字段 | 语义 | 何时生效 |
| --- | --- | --- |
| `Depends` | 运行时依赖 | 安装与卸载都检查 |
| `BuildDepends` | 构建期依赖 | 只影响能否构建 |
| `RuntimeDepends` | 由 dpkg 记录的运行时依赖（不参与 Fink 求解） | 交给 dpkg |
| `Conflicts` / `Replaces` | 互斥与替代 | 求解时剪枝 |
| `Provides` | 虚拟提供 | 满足依赖 |
| `Essential` | 不可移除，`selfupdate` 时总是更新 | 全局 |
| `Suggests` / `Recommends` | 建议 | 不强制 |

两道关卡：

1. **构建期**：`Fink::Package` 从包描述集合求解，`Finally::BuildConflicts` 拦冲突，
   `Finally::Buildlock` 防并发构建同一个包。
2. **落地前**：`Fink::SysState` 做一次系统级一致性检查（[SysState.pm](../perlmod/Fink/SysState.pm:943)），
   失败即中止；它带 `checkpoint` / `undo`，可以在中途回退。

虚拟包通过 [VirtPackage](../perlmod/Fink/VirtPackage.pm) 生成，再以 dpkg status 的形式
喂给 dpkg / apt（[fink-virtual-pkgs.in](../fink-virtual-pkgs.in) 提供 `--dpkg` / `--apt` 两种输出）。
这是 macOS 没有 X11、没有真 gcc 时，让 dpkg 的依赖求解仍然成立的关键手段。

---

## 五、dpkg 定制

[dpkg.info](../10.9-libcxx/dpkg.info) 打 12 个补丁，其中五个是硬需求：

| 补丁 | 解决什么 |
| --- | --- |
| `protect-system-dirs` | Darwin 的 `/etc`、`/var`、`/tmp` 是 symlink；dpkg 卸掉最后一个包时会把它当空目录删掉。补丁强行认为它们"被占用" |
| `so-to-dylib` | 给 `Dpkg/Shlibs/Objdump.pm` 加 `is_mach_o`，认 32/64 位与 fat Mach-O |
| `extra-statusfile` | 新增 `FINKSTATUSFILE "status-fink"` 第二个状态文件 |
| `fink-as-vendor` | 让 dpkg 接受 Fink 作为 vendor |
| `fink-bld_no_fakeroot` | 去掉 fakeroot 依赖 |

另外用 `awk` 往 `data/cputable` 与 `data/tupletable` 插入 `aarch64` / `darwin-arm64` 表项 ——
**Apple 芯片支持是靠给 dpkg 打表实现的**，不是靠上游。

---

## 六、锁与并发

dpkg 自己的锁不够，Fink 在前面加一层 [lockwait.in](../lockwait.in)：

1. 打开 `$prefix/var/lib/dpkg/lock`；
2. `fcntl(F_SETLK)` 抢写锁，失败则 `F_SETLKW` 等，超时 5 分钟；
3. 清掉 close-on-exec，再 `exec` 真程序 —— 让被 exec 的进程继承锁；
4. 失败时明确提示"该文件系统不支持锁，请勿并发运行"。

`pack()` 是**照着 Darwin 的 `struct flock` 手工拼的**（注释里把 `fcntl.h` 与 `_types.h`
的字段宽度抄了出来）。因为不能依赖编译型 CPAN 模块，只能用 `qqiss` 这种硬编码格式。

---

## 七、网络与镜像

所有网络出口都在 [NetAccess](../perlmod/Fink/NetAccess.pm)：

- 优先 `$prefix/bin/curl`，否则 `/usr/bin/curl`；
- `--connect-timeout 30`，`DownloadTimeout` 可追加 `--max-time`；
- `DownloadMethod=wget` 时回退 wget，但 `file://` 仍强制用 curl；
- `ProxyPassiveFTP` 关闭时加 `-P -`。

[Fink::Mirror](../perlmod/Fink/Mirror.pm) 负责把包描述里的
`mirror:sourceforge:…` 展开成具体 URL：`Primary` / `Secondary` 分级、
`get_site_retry` 轮换、按地域列候选。

现实约束：核心包描述的 `CustomMirror` 大量指向 `dl.sourceforge.net` 的二十多个节点。
**这不是"感觉慢"，是代码里的事实。**

---

## 八、面向用户的新安装器（设计）

### 8.1 目标

对照一节的五个脆弱点，新安装器必须满足三条硬要求：

| 要求 | 为什么 |
| --- | --- |
| 不编译 | 安装时不需要 Xcode、不需要 12 个补丁成功、不需要系统 perl |
| 强校验 | SHA256 不符即中止，不做"警告后继续" |
| 可重入、可观测 | 断点续传、已装则修复、每步有明确输出，失败能定位到具体文件 |

### 8.2 三个候选方案

| 方案 | 做法 | 优点 | 代价 |
| --- | --- | --- | --- |
| **A. 二进制种子** | 预编译 dpkg + 依赖树 + fink 打成一个 tar，脚本下载校验后解压 | 秒级、无需编译器、行为确定 | 需要持续产出种子；新 macOS 版本要有种子 |
| **B. 保留自举，现代化脚本** | 仍从源码编 dpkg，但改成无人值守、幂等、进度可视 | 不依赖任何预编译产物 | 仍要 Xcode、仍会因补丁失败而中断；本质没变 |
| **C. 混合（推荐）** | 有种子走 A，无种子自动回退 B | 新系统不至于无路可走 | 两条路径都要维护 |

推荐 **C**：A 是主路径，B 降级为兜底与种子生产工具。

### 8.3 种子是什么

**种子 = 一台参考机上 `bootstrap` 成功之后的 `/opt/finx` 快照**，去掉 `src/` 缓存与
与机器相关的配置。不是手工拼装的产物，所以不会与自举结果漂移。

内容（即 14 个发行版 Essential 包 + 仓库根注入的 `fink` 本身）：

```
/opt/finx/bin/{dpkg,dpkg-deb,dpkg-query,dpkg-lockwait,fink,fink-scanpackages,…}
/opt/finx/lib/{libgettext*,liblzma*,libbz2*,libiconv*,…}.dylib
/opt/finx/lib/perl5/Fink/…            ← 纯 Perl，架构无关
/opt/finx/etc/fink.conf               ← 模板，留 Basepath 占位
/opt/finx/var/lib/dpkg/{status,status-fink,available}
/opt/finx/fink/dists → <distribution>
```

**为什么种子必须是 `/opt/finx`**：dylib 的 `install_name` 在构建时就被写成
`/opt/finx/lib/...`，Mach-O 里没有"相对前缀"这回事。参考机装在规范前缀，种子天生可用；
换个前缀就要重做重定位与签名。**规范前缀不是审美选择，它是二进制分发能够存在的前提。**

推而广之：`dpkg` 是普通 C 程序，除 `init.sh` 路径外没有系统耦合，因此
**按架构出一份**即可（`x86_64` / `arm64`，或 universal2），不需要每个 macOS 版本一份。
注意 universal2 的两个 slice 可以有各自的最低版本：`x86_64` 可到 10.9，`arm64` 最低 11.0。

### 8.4 manifest 与校验

清单是**行取向的纯文本**，不是 JSON —— 安装阶段不该依赖 `jq`，而 `awk` 一行就能取字段，
diff 与签名也都更方便。字段与解析器见 [`finx-install/lib/manifest.sh`](../finx-install/lib/manifest.sh)。

```
schema  1
release 0.46.0
arch    arm64
seed    seed.tar.gz
size    12345678
sha256  <64 位十六进制>
url     https://host/a/seed.tar.gz
url     https://host/b/seed.tar.gz
```

规则：

- `schema` / `arch` / `seed` / `size` / `sha256` 必填，至少一条 `url`。
- `seed` 不得含路径分隔符；`size` 必须是字节数。
- 体积与 SHA256 都核对，任一不符即中止，不做「警告后继续」。
- 下载写 `.part` 临时后缀，成功后改名 —— 天然支持 `curl -C -` 续传。
- 只有全部 `url` 都失败才判定失败，中间失败视作镜像故障并降级。

### 8.5 安装器流程

```
1. 体检      macOS 版本 / arch / 目标目录状态 / 写权限
2. 解析清单  本地目录（--seed-dir）或远端（--manifest-url）
3. 取产物    本地拷贝，或按 url 逐个尝试（.part 续传）
4. 校验      size + sha256，不符即中止
5. 落盘      mkdir 前缀 → tar 解到 /opt/finx（dpkg 要求扁平树，不能 package@version）
6. 收尾      权限归一；Mach-O ad-hoc 重签名；写 fink.conf
7. 收束      fink scanpackages → 提示 source <prefix>/bin/init.sh
```

顺序上有一处是刻意的：**校验在第 5 步之前**，失败时不会留下一个空壳目录。

全部步骤无交互；`--dry-run` 只打印将要做什么。`--seed-dir` 让整条流程可以完全离线自测，
这也是它成为一等公民参数的原因。

`FINX_TEST=<绝对路径>` 把整次运行关进该目录（作用等同于 MacWave 的 `MACWAVE_TEST`）：
默认前缀变成 `<测试根>/opt/finx`，`TMPDIR` 改到 `<测试根>/tmp`，`--prefix` 越界即中止。
相对路径、`/`、解析后落在系统目录的路径一律拒绝 —— 测试根写错时宁可中止，也不降级到真实目录。
`finx-install/selftest.sh` 用这个机制跑 19 项断言，全程离线。

### 8.6 前缀归属：必须是 root

**`/opt/finx` 归 root 所有，安装器不会把它 chown 给调用者。** 这不是保守，是两个具体后果：

**一、chown 达不到"免密码"。** `install` 在命令表里的 `rootflag` 是 1
（[Engine.pm:96](../perlmod/Fink/Engine.pm:96)），`process` 拿到就先
[restart_as_root](../perlmod/Fink/Engine.pm:346)：

```perl
sub restart_as_root {
    return if $> == 0;
    ...
    $cmd = "/usr/bin/sudo $env $cmd";
```

判断只看 `$>`，与前缀归属无关。所以就算把 `/opt/finx` 给了用户，装第一个包时照样弹密码 ——
只是把一次密码推迟成每次。

**二、chown 会开一个本地提权口子。** dpkg 以 root 执行包的 `postinst`，而 Fink 的 dpkg
打了 `fink-bld_no_fakeroot` 补丁（[dpkg.info](../10.9-libcxx/dpkg.info:58)），用的是**真 root**。
前缀一旦用户可写，该用户就能：

| 改什么 | 后果 |
| --- | --- |
| `$prefix/bin/dpkg` | 下次 root 跑 `dpkg -i`，执行的是用户的程序 |
| `$prefix/var/lib/dpkg/status` | 伪造「已安装」，诱导级联卸载或跳过依赖 |
| `$prefix/src/*.tar`、`--force` 时的 .deb | dpkg 以 root 解包并执行其中的脚本 |

所以安装器以 root 运行时统一把整棵前缀归一为 `root:wheel`
（[extract.sh](../finx-install/lib/extract.sh) 的 `fix_permissions`）；非 root 只可能发生在
`FINX_TEST` 沙箱或用户自己的前缀里，此时**不碰归属**，只告警。

**真正免密码的路是换前缀，不是 chown。** 参照 MacWave 的用户级安装
（`~/.local/macwave`，见其 `lib/configpaths.py`）。Fink 走这条路要同时解开三个结：

| 结 | 现状 | 代价 |
| --- | --- | --- |
| `bindist_check_prefix` 钉死 `/opt/finx` | [Config.pm:858](../perlmod/Fink/Config.pm:858) | 改一行，但要同时决定用户前缀还能不能用官方二进制包 |
| dylib `install_name` 是绝对路径 | 构建期写死 `$prefix/lib/...` | **用户前缀无法复用现有 .deb**，必须自带按该前缀构建的种子 |
| 配置位置 | `$prefix/etc/fink.conf` | 已是相对路径，天然支持 |

也就是说，"免密码"的成本不是一行 chown，而是一整套按用户前缀构建的二进制分发。
在做出那个决定之前，保持 root 所有是唯一安全的选择。

**这相当于 MacPorts 的模型**：安装与每次装包都要 `sudo`，但每个操作都作用在系统级前缀上，
不需要为不同的前缀准备不同的二进制包。Finx 采纳这个模型，因此：

- 安装器在非 root 时拒绝写系统前缀（`require_write_access`）；
- 装包时由 `restart_as_root` 自动 `sudo`，用户不必手动加；
- 两条路径共用同一份 `/opt/finx` 二进制分发，不需要按用户重建。

### 8.7 命名决定

面向用户的安装器是一个目录：**`finx-install/`**。

```
finx-install/
├── install.sh            模块化入口
├── standalone.sh         生成物：自包含单文件，供 curl | bash
├── build-bundle.sh       打平脚本（带 --check 防漂移）
├── selftest.sh           FINX_TEST 沙箱自测
├── lib/{common,detect,manifest,extract}.sh
└── seed/manifest.example
```

用户看到的是那条命令：

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fincote/Finx/HEAD/finx-install/standalone.sh)"
```

单文件必须提交进仓库，因为 `curl | bash` 只拿得到一个文件，被管道执行时既没有可靠的 `$0`，
也没有同级目录可以 `source`。代价是**改完 `lib/` 必须重新生成**，由 `build-bundle.sh --check`
在 CI 里兜住漂移。

**根目录的 `install.sh` 不改名。** 它不是孤立脚本名，而是「每个包的安装阶段脚本」这一约定的
成员 —— `.info` 的 `InstallScript` 写的是相对构建目录的 `./install.sh`，四个包共用：

| 包 | 源码在哪 | 可改 |
| --- | --- | --- |
| `fink` | 仓库根 | 可 |
| `fink-mirrors` | `mirror/` | 可 |
| `base-files` | 外部 tarball | 不可 |
| `dpkg-base-files` | 外部 tarball | 不可 |

只改前两个会在 `.info` 层制造两套约定。而且改名要同步 `MANIFEST` 与
`Bootstrap::check_files` 两份**互相独立**的清单，漏一处就在自举第一步炸掉。
所以新东西另起专名，旧约定原样保留。

### 8.8 仍待定

| 待定 | 选项 | 影响 |
| --- | --- | --- |
| 兜底是否保留 | 保留自举 / 宁可失败 | 保留则要一直维护两条路径；删除则新 macOS 首发当天无法安装 |
| 种子分发源 | GitHub Releases / 自建镜像 | 决定清单地址、可用性下限与校验锚点 |

---

## 九、测试

套件在 `t/`，Test::Harness 驱动。**基线：48 个测试文件、1059 项断言。**

```
make test        # manifest_check → test_setup → 跑完 t/ 全部测试
```

`make test` 的三个阶段各有分工：

| 阶段 | 作用 |
| --- | --- |
| `manifest_check` | `MANIFEST` 必须列出仓库里每个文件（漏了就不会进发行 tarball），同时 `MANIFEST.SKIP` 必须排除全部生成物 |
| `test_setup` | `./setup.sh t/basepath x86_64`，生成 `fink` / `postinstall.pl` / `lockwait` / `FinkVersion.pm` 等运行时文件 |
| 测试本体 | `cd t && ./testmore.pl && find . -name '*.t' \| sort \| PREFIX=... xargs perl -MTest::Harness` |

维护 `MANIFEST` 的两条经验：

- **要随程序分发的文件必须登记。** `install.sh` 会装 `readme.*.html`，而
  `readme.de.html` 曾经漏登记 —— 结果是德文 readme 长期不在发行包里，且
  `manifest_check` 一直红着，把这条真问题掩盖掉了。
- **生成物要同时进 `MANIFEST.SKIP` 与 `.gitignore`。** 只加一处会出现"git 干净了但
  tar 里混进生成物"，或反之。`setup.sh` 生成的 `compiler_wrapper-10.7` / `-10.9`
  就曾漏在 `MANIFEST.SKIP` 之外，导致每次 `make test_setup` 之后 `make test` 都失败。
  排除模式写成 `^compiler_wrapper(-\d+\.\d+)?$`，注意别把 `.in` 源文件一起吞掉。

只想跳过完整性检查、直接跑测试时：

```
make test_setup
cd t && ./testmore.pl && find . -name '*.t' | sort | \
    PREFIX=/opt/finx xargs /usr/bin/perl -I$(pwd)/../perlmod -MTest::Harness -e 'runtests(@ARGV)'
```

`t/basepath/` 是一套假安装，`PREFIX` 只影响少数用例。

安装器自己的测试走 `FINX_TEST` 沙箱，不碰真实目录：

```
./finx-install/selftest.sh                              # 自建临时根，跑完删除
FINX_TEST=/tmp/finx-check ./finx-install/selftest.sh     # 指定根，保留结果
```

**手工验证安装器时必须带 `FINX_TEST`。** 不带的话默认前缀就是真实的 `/opt/finx`，
会真的往机器上装东西。

---

## 十、已知问题与地雷

| 问题 | 症状 | 状态 |
| --- | --- | --- |
| `manifest_check` 曾经必然失败 | 见 10.1 | **已修** |
| `setup.sh` 变量拼写错误 | 第 117 行把 `$basepath` 写成 `$basepeath`，`compiler_wrapper-10.9` 里的前缀被替换成空串 | 未修。属于既有缺陷，不在前缀迁移范围内 |
| phase 2 被执行两次 | [bootstrap:777](../bootstrap) 附近连续两行 `execute`，第一次的返回值被丢弃 | 未修。会白跑一遍自举 |
| 两个锁实现不一致 | `lockwait.in` 用可配置的 `pack(@PACKARGS@,…)`，`fink-dpkg-status-cleanup.in` 硬编码 `pack("lllliss",…)`，而文件头写着"KEEP THIS IN SYNC" | 未修。64 位下偏移恰好一致，32 位会错位 |
| 安装文档版本滞后 | [INSTALL](../INSTALL:3) 是 0.45.6，[Install.md](../Install.md:1) 还是 0.41.1，`VERSION` 是 0.45.99.git | 未修。新文档以本手册为准 |
| `NEWS` 里的旧路径 | 历史条目仍写 `/sw`、`/opt/sw` | 刻意保留，见 [AGENTS.md](../AGENTS.md) |

### 10.1 已修：`manifest_check` 必然失败

原因不止一个，拆开看：

| 症状 | 根因 | 修法 |
| --- | --- | --- |
| `Not in MANIFEST: readme.de.html` | 该文件确实没登记，而 `install.sh` 会装 `readme.*.html` —— **德文 readme 从未进过发行包** | 登记进 `MANIFEST` |
| `Not in MANIFEST: compiler_wrapper-10.7` / `-10.9` | 它们由 `setup.sh` 从 `.in` 生成，而 `MANIFEST.SKIP` 只写了 `^compiler_wrapper$` | 改为 `^compiler_wrapper(-\d+\.\d+)?$`，`.gitignore` 同步加 `/compiler_wrapper-*` |

排除模式不能图省事写成 `^compiler_wrapper-.*$`：那样会把 `compiler_wrapper-10.6.in`
这类**源文件**一起排除，tarball 里就缺模板，构建直接失败。正则里的 `\d+\.\d+` 就是为了
停在版本号上。

这个缺陷真正危险的地方在于它长期"只是红着"：`make test` 第一步就退出，于是后面的测试
从来没跑过；而它同时压住了 `readme.de.html` 那个真 bug —— **一个假警报掩护了一个真问题**。

维护 `MANIFEST` 的两条规则因此固定下来：

- 要随程序分发的文件必须登记（`install.sh` 里的 `for file in ...` 列表是最好的对照）；
- 生成物要**同时**进 `MANIFEST.SKIP` 与 `.gitignore`，只加一处会出现"git 干净了但
  tarball 里混进生成物"，或反之。
