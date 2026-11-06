# Finx 技术手册

> 目标：讲清「为什么这样设计」。文件在哪、归谁管，见 [Structure.md](./Structure.md)。
>
> 适用版本：`1.0.0-beta1`

## 目录

1. [安装体系现状](#一安装体系现状)
2. [finx 如何安装自己](#二fink-如何安装自己) —— 含 2.1 版本号与修订号的来源
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
        │  用户手动下载 finx-<ver>.tar.gz  ← 唯一需要用户动手的下载
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
| 铺骨架 | [bootstrap:630](../bootstrap) | `etc etc/apt src finx/debs var/lib/dpkg var/lib/finx …` |
| 把自己变成包 | [create_tarball](../perlmod/Fink/Bootstrap.pm:792) | 按 `MANIFEST` 打 `$prefix/src/finx-<ver>.tar` |
| 写包描述 | [copy_description](../perlmod/Fink/Bootstrap.pm:858) | 填 MD5/SHA256，`Source` 指向刚打的 tar，追加 `NoSourceDirectory: true` |
| 阶段一 | [bootstrap1](../perlmod/Fink/Bootstrap.pm:492) | 只编 tar-bootstrap / dpkg-bootstrap，**绕过包管理**，落进 `$prefix/bootstrap` |
| 阶段二 | [bootstrap2](../perlmod/Fink/Bootstrap.pm:586) | 用目标 perl 重新 exec `bootstrap-phase2.pl`，首次走 `cmd_install` |
| 阶段三 | [bootstrap3](../perlmod/Fink/Bootstrap.pm:632) | 删掉脚手架 |
| 建索引 | [bootstrap:860](../bootstrap) | `finx scanpackages` 生成 `Packages.gz` |

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

## 二、finx 如何安装自己

finx 对自己没有特殊待遇 —— 它把自己变成一个包，然后按普通包安装。

| 路径 | 入口 | 源码从哪来 | 是否经过 dpkg |
| --- | --- | --- | --- |
| 首装 | [bootstrap](../bootstrap) | 用户下载的 tarball，`MANIFEST` 本地打包 | 阶段一否，阶段二是 |
| 注入（开发者） | [inject.pl](../inject.pl) → [inject_package](../perlmod/Fink/Bootstrap.pm:282) | 当前工作副本 | 是 |
| 自更新 | [SelfUpdate::finish](../perlmod/Fink/SelfUpdate.pm:312) | 包描述里的 `Source`（发布 tarball） | 是 |

`inject_package` 的最后一步最能说明它的本质：

```perl
&execute("/usr/bin/perl $bpath/bin/finx install $package-$packageversion-$packagerevision")
```

**用旧 finx 装新 finx。** 三条路径共用同一套 `setup.sh` + `install.sh` + `dpkg-deb -b`。

因为 `finx` 声明了 `Essential: yes`，`selfupdate` 的
`cmd_install(list_essential_packages())` 天然会把它自己包含进去，不需要专门的
"升级自己"分支。

### 2.1 包版本号与修订号从哪来

`finx` 包的 `Version` / `Revision` 都不是手写的，`finx.info.in` 里是 `@VERSION@`
与 `@REVISION@` 两个占位符，由 [get_version_revision](../perlmod/Fink/Bootstrap.pm:1129)
在注入时算出来。它的输入只有两个文件，行为却分两条路（判据在
[read_version_revision](../perlmod/Fink/Bootstrap.pm:1092)）：

| `VERSION` 的内容 | 修订号取什么 | 例 |
| --- | --- | --- |
| 含 `cvs` / `svn` / `git` | **当前时间**，`YYYYMMDD.HHMM` | `0.1.0-alpha.git-20261104.0444` |
| 其它（正式版本号） | `REVISION` 里 `<distribution>: <n>` 那一行的 `n` | `1.0.0-beta1-181`（`12.0: 181`） |

这条规则有一个副作用，发布前必须知道：

- **带 `git` 的版本号天然唯一。** alpha 阶段每次构建都得到不同的修订号，所以
  同一个 `VERSION` 反复出包不会撞车 —— 那也正是当时把 `.git` 缀在后面的原因之一。
- **正式版本号不唯一。** 从 `1.0.0-beta1` 起，任何机器上重打都会得到同一个
  `finx-1.0.0-beta1-181`。**要重新出包，就必须先改 `REVISION` 里对应发行版那一行**
  （例如 `12.0: 181` → `182`），否则新包与旧包版本串相同：`dpkg` 认为无事可做，
  `selfupdate` 也不会升级自己。

`VERSION` 是唯一源头：`setup.sh` 由它生成 `perlmod/Fink/FinkVersion.pm`（生成物，
已 gitignore），[make_seed.sh](../scripts/make_seed.sh:132) 由它写种子清单的
`release` 字段。所以改版本号之后**必须重打种子**，否则用户装完看到的还是旧版本号。

树的 `.info` 里那 17 处 `BuildDepends: finx (>= 0.1.0-alpha)` 是下限，不是精确值 ——
版本号往前走不会破坏它们。

---

## 三、装包流水线

`finx install foo` → [real_install](../perlmod/Fink/Engine.pm:1730)：

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

### `InstallScript` 必须写 `%i`，不能写 `%p`

构建默认以 `fink-bld` 运行（`BuildAsNobody` 默认 1），而 `%p` 归 root —— 在
`InstallScript` 里往 `%p/bin` 装东西会直接 EACCES。首次给树里加 `tree` 时就栽在这里：
`make install PREFIX=%p` 报 `Error 71`，原因就是 `install tree /opt/finx/bin/tree`
以 `fink-bld` 写不进 root 的目录。

所以：**产物一律装进 `%i`**，由 `dpkg` 以 root 在 `phase_activate` 时落到真实前缀。
`%p` 在 `InstallScript` 里只用于**引用**（读已有文件、往脚本里写绝对路径），不用于写。

例外是声明了 `BuildAsNobody: false` 的包 —— `tar`、`dpkg` 这类必须 root 构建的；
它们以 `root:admin` 运行，`%p` 可写。

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
喂给 dpkg / apt（[finx-virtual-pkgs.in](../finx-virtual-pkgs.in) 提供 `--dpkg` / `--apt` 两种输出）。
这是 macOS 没有 X11、没有真 gcc 时，让 dpkg 的依赖求解仍然成立的关键手段。

---

## 五、dpkg 定制

[dpkg.info](../10.9-libcxx/dpkg.info) 打 12 个补丁，其中五个是硬需求：

| 补丁 | 解决什么 |
| --- | --- |
| `protect-system-dirs` | Darwin 的 `/etc`、`/var`、`/tmp` 是 symlink；dpkg 卸掉最后一个包时会把它当空目录删掉。补丁强行认为它们"被占用" |
| `so-to-dylib` | 给 `Dpkg/Shlibs/Objdump.pm` 加 `is_mach_o`，认 32/64 位与 fat Mach-O |
| `extra-statusfile` | 新增 `FINKSTATUSFILE "status-finx"` 第二个状态文件 |
| `finx-as-vendor` | 让 dpkg 接受 Fink 作为 vendor |
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
| **A. 二进制种子** | 预编译 dpkg + 依赖树 + finx 打成一个 tar，脚本下载校验后解压 | 秒级、无需编译器、行为确定 | 需要持续产出种子；新 macOS 版本要有种子 |
| **B. 保留自举，现代化脚本** | 仍从源码编 dpkg，但改成无人值守、幂等、进度可视 | 不依赖任何预编译产物 | 仍要 Xcode、仍会因补丁失败而中断；本质没变 |
| **C. 混合（推荐）** | 有种子走 A，无种子自动回退 B | 新系统不至于无路可走 | 两条路径都要维护 |

推荐 **C**：A 是主路径，B 降级为兜底与种子生产工具。

### 8.3 种子是什么

**种子 = 一台参考机上 `bootstrap` 成功之后的 `/opt/finx` 快照**，去掉 `src/` 缓存与
与机器相关的配置。不是手工拼装的产物，所以不会与自举结果漂移。

内容（即 14 个发行版 Essential 包 + 仓库根注入的 `finx` 本身）：

```
/opt/finx/bin/{dpkg,dpkg-deb,dpkg-query,dpkg-lockwait,finx,finx-scanpackages,…}
/opt/finx/lib/{libgettext*,liblzma*,libbz2*,libiconv*,…}.dylib
/opt/finx/lib/perl5/Fink/…            ← 纯 Perl，架构无关
/opt/finx/finx/{10.9-libcxx,26.0,dists,debs}   ← 二进制池与描述树；
                                      debs 里是形如 <name>.deb -> ../26.0/... 的相对链接
/opt/finx/var/lib/dpkg/{status,status-finx,available}
                                      ← etc/finx.conf 不进种子：安装器按实际前缀重写
/opt/finx/finx/dists → <distribution>
```

**为什么种子必须是 `/opt/finx`**：dylib 的 `install_name` 在构建时就被写成
`/opt/finx/lib/...`，Mach-O 里没有"相对前缀"这回事。参考机装在规范前缀，种子天生可用；
换个前缀就要重做重定位与签名。**规范前缀不是审美选择，它是二进制分发能够存在的前提。**

推而广之：`dpkg` 是普通 C 程序，除 `init.sh` 路径外没有系统耦合，因此
**按架构出一份**即可（`x86_64` / `arm64`，或 universal2），不需要每个 macOS 版本一份。
注意 universal2 的两个 slice 可以有各自的最低版本：`x86_64` 可到 10.9，`arm64` 最低 11.0。

**产出方式**：`scripts/make_seed.sh --prefix /opt/finx --out seed`，生成 `seed.tar.gz` 与
`manifest`。CI 的 `bootstrap.yml` 在自举成功后自动跑它，把两者一起作为 `finx-seed`
产物上传 —— 解开就是 `install.sh --seed-dir=<目录>` 能直接吃的东西。

### 8.4 manifest 与校验

清单是**行取向的纯文本**，不是 JSON —— 安装阶段不该依赖 `jq`，而 `awk` 一行就能取字段，
diff 与签名也都更方便。字段与解析器见 [`finx-install/install.sh`](../finx-install/install.sh)。

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
6. 收尾      权限归一；Mach-O ad-hoc 重签名；写 finx.conf
7. 收束      finx scanpackages → 提示 source <prefix>/bin/init.sh
```

顺序上有一处是刻意的：**校验在第 5 步之前**，失败时不会留下一个空壳目录。

全部步骤无交互。`--seed-dir` 让整条流程可以完全离线自测，这也是它成为一等公民参数的原因。

`FINX_TEST=<绝对路径>` 把整次运行关进该目录（作用等同于 MacWave 的 `MACWAVE_TEST`）：
默认前缀变成 `<测试根>/opt/finx`，`TMPDIR` 改到 `<测试根>/tmp`，`--prefix` 越界即中止。
相对路径、`/`、解析后落在系统目录的路径一律拒绝 —— 测试根写错时宁可中止，也不降级到真实目录。
`finx-install/selftest.sh` 用这个机制跑全套断言，全程离线。

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
（[extract.sh](../finx-install/install.sh) 的 `fix_permissions`）；非 root 只可能发生在
`FINX_TEST` 沙箱或用户自己的前缀里，此时**不碰归属**，只告警。

**真正免密码的路是换前缀，不是 chown。** 参照 MacWave 的用户级安装
（`~/.local/macwave`，见其 `lib/configpaths.py`）。Fink 走这条路要同时解开三个结：

| 结 | 现状 | 代价 |
| --- | --- | --- |
| `bindist_check_prefix` 钉死 `/opt/finx` | [Config.pm:858](../perlmod/Fink/Config.pm:858) | 改一行，但要同时决定用户前缀还能不能用官方二进制包 |
| dylib `install_name` 是绝对路径 | 构建期写死 `$prefix/lib/...` | **用户前缀无法复用现有 .deb**，必须自带按该前缀构建的种子 |
| 配置位置 | `$prefix/etc/finx.conf` | 已是相对路径，天然支持 |

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
├── install.sh           唯一源文件，约 2000 行，供 curl | bash
├── selftest.sh          FINX_TEST 沙箱自测
└── seed/manifest.example
```

用户看到的是那条命令：

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fincote/Finx/HEAD/finx-install/install.sh)"
```

单文件是**唯一源文件**，直接编辑它。`curl | bash` 只拿得到一个文件，被管道执行时既没有可靠的
`$0`，也没有同级目录可以 `source` —— 所以安装器不能拆成多个 `.sh`。

这里曾经有过相反的选择：`install.sh.in` 模板 + `lib/*.sh` 模块，由 `build-bundle.sh` 拼成单文件，
CI 用 `--check` 防漂移。那套已拆掉。2000 行在一个文件里是可以直接维护的，而「模板 + 生成物 +
同步校验」的真实代价不是那几个脚本，是**改了产物会被下次构建静默覆盖** —— 人的手改和脚本的
输出指向同一个文件，出错时没有任何提示。现在只有一处可改，那个失败模式就不存在了。

单文件下要自己守两条纪律：模块边界靠注释分段（而不是文件系统），以及 `set -eE` 与「返回非零是
正常信号」的函数之间的冲突必须显式处理（例如 `probe_url` 用 `PROBE_RESULT` 传结果、不传退出码）。
`selftest.sh` 是这两条唯一的防线。

**根目录的 `install.sh` 不改名。** 它不是孤立脚本名，而是「每个包的安装阶段脚本」这一约定的
成员 —— `.info` 的 `InstallScript` 写的是相对构建目录的 `./install.sh`，四个包共用：

| 包 | 源码在哪 | 可改 |
| --- | --- | --- |
| `finx` | 仓库根 | 可 |
| `fink-mirrors` | `mirror/` | 可 |
| `base-files` | [`base-files/`](../base-files/) | 可（已内置，见 8.9） |
| `dpkg-base-files` | 外部 tarball | 不可 |

只改前两个会在 `.info` 层制造两套约定。而且改名要同步 `MANIFEST` 与
`Bootstrap::check_files` 两份**互相独立**的清单，漏一处就在自举第一步炸掉。
所以新东西另起专名，旧约定原样保留。

### 8.8 决策：种子分发源 = GitHub Releases + 自建镜像

**结论：种子放在 GitHub Releases，清单里的第二条 `url` 指向我们自己的镜像。
种子本身绝不提交进 git 仓库。**

#### 为什么不是「把种子放进仓库」

git 对单个文件有 **100 MiB 硬限**，超了连 push 都会被拒。种子是 14 个 Essential 包
加 `finx` 本体的编译产物（见 8.3），是二进制，没有"改几行再提交"的余地 —— 一旦进来，
仓库历史会随每次重建种子而膨胀，而历史是删不掉的。这条限制不能绕过，
只能换个地方存。

GitHub Releases 的资产是另一套存储：**单文件上限 2 GiB**，公开仓库的下载不计费、
不计流量。种子的体积离这两个数都很远，所以 `Releases` 是唯一"不花钱、不运维、
地址稳定"的选项。

#### 为什么不能只放自建镜像

单点。种子是**用户机器上第一个要拿到的东西**，它取不到，整条安装就停在第一步 ——
而那时用户手上还没有 Finx，也就没有别的手段可用。所以必须至少有一个不需要我们
运维的兜底，且清单里两条 `url` 都写全（`finx-install/install.sh` 的
`fetch_artifact` 会逐条尝试，只有全部失败才中止）。

反过来也不能只靠 Releases：它在部分网络里不可达，而这恰恰是要自建镜像的原因。
两者的关系不是主备，而是**两份内容逐字节相同的副本**，见下一节。

#### 地址形状：镜像只需 rsync 一棵平铺树

Releases 的下载地址恒定是「域名 + 固定前缀 + `/<tag>/<资产名>`」：

```
https://github.com/Fincote/Finx/releases/download/seed-24/seed.tar.gz
└──────────────── 恒定 ─────────────────┘└─tag─┘└─资产名─┘
```

标签是 `seed-<Darwin 主版本>`（安装器按 `uname -r` 拼出来），资产名固定是
`seed.tar.gz` 与 `manifest`。

自建镜像只要提供**最后两段**，形状就完全一致：

```
https://mirror.finx.sh/finx/seed/seed-0.46.0-arm64.tar.gz
```

于是镜像站的构建方式变成一句话：**把 Release 资产按 `<tag>/<文件名>` 摊平放进去，
换个域名即可**。不需要写接口、不需要重写路径、不需要关心 tag 的语义。这条约束值得
写进镜像站的搭建说明，因为一旦开始"顺手美化一下路径"，两边就不再同形，
清单里的两条 `url` 也就不能互换了。

命名与发布规则：

| 项 | 规则 | 理由 |
| --- | --- | --- |
| tag | 固定 `seed`，滚动 | tag 在这里只是分类，不承载版本语义；版本写在资产名里 |
| 资产名 | `seed-<release>-<arch>.tar.gz` | 带版本与架构，所以新种子是**新文件**，不覆盖旧的 |
| 只增不删 | 从不覆盖同名资产，同名同大小则跳过 | 旧种子留着就是回滚路径；覆盖会打断已经发出的清单 |
| 清单里 `seed` 字段 | 固定写 `seed.tar.gz` | 它只是解压前的本地文件名，与 `url` 末段无关 |
| 磁盘落点 | `$FINX_TMP/$SEED_NAME` | 见 `manifest.sh` 的 `ARTIFACT_FILE` |

#### 清单放哪：它是校验锚点，不能和产物同源

清单里有 `sha256`。**如果清单和被校验的产物来自同一台机器，那台机器被入侵就等于
校验失效** —— 攻击者同时改产物和它的 `sha256`，安装器会一路放行。

所以清单放在**本仓库**：

```
finx-install/seed/manifest-arm64.txt
finx-install/seed/manifest-x86_64.txt      ← 按架构分开，arch 字段与文件一致
```

理由：它公开、有 commit 记录、可以 `git log -p` 审计。想改它就得改仓库历史，
这比改一个服务器上的文件显眼得多。代价是每换一次种子要提交一次清单 ——
这恰好是应该的：**换种子是一次发布动作，不该是 CI 里的副作用。**

镜像可以放一份内容相同的副本供 `--manifest-url` 使用（国内网络下 raw 未必可达），
这时信任来自"它是同一份文件"，而不是来自 host。默认值指向仓库那一份。

**锚点链的现状（一处已知弱环）：** 用户信任的起点是他执行的那条命令，即
`raw.githubusercontent.com/.../HEAD/finx-install/install.sh`（见 8.7）。`HEAD`
是移动的，且这个脚本本身没有 `sha256` 可供核对。种子这一层的校验是扎实的，
但"下载安装器的那个动作"仍是信任条款而非校验。缓解方式是在发布页同时给出
版本化的 tag 地址与 `shasum`，让需要可复现性的用户改用 `refs/tags/<ver>`
而不是 `HEAD`。这条不阻塞本决策，但不要以为整条链都已经有校验。

#### 这条决策落到代码上的三处

1. **`MANIFEST_URL` 要有默认值。** 现在是空（`finx-install/install.sh` 第 52 行），
   必须显式传 `--manifest-url`，`curl | bash` 才能用。默认值要按探测到的架构拼
   `.../HEAD/finx-install/seed/manifest-$HOST_ARCH.txt` —— 注意 `HOST_ARCH` 在体检
   那一步才有值，所以默认值的计算要放在**体检之后、取清单之前**，不能留在
   第 52 行。
2. **种子产物要同时进 `.gitignore` 与 `MANIFEST.SKIP`。** 两份都要，理由见
   [`AGENTS.md`](../AGENTS.md) 的测试一节：只加一处会出现"git 干净了但 tar 里混进
   生成物"，或反之。目前的 `.gitignore` 与 `MANIFEST.SKIP` 都还没有这条。
3. **镜像体检要覆盖两条 `url`。** "两条 url 都写全"只有在真的取得到时才算可用性下限；
   定期验一遍是 [`Todo.md`](../Todo.md) 里那条待办（mirror check utility）该做的事 ——
   验法不能只看 HTTP 200，要比对字节数与 `sha256`。

### 8.9 内置源码包：base-files

`base-files` 是 `Essential: yes` 的目录基础设施包，提供 `bin/init.sh`、`bin/init.csh`、
`bin/{pager,editor}`、`share/base-files/dir-base`，以及 `bin`、`etc`、`var/lib/dpkg`
那套目录骨架。它以前只在 SourceForge 上的 `finx/base-files-1.9.19.tar.gz` 里。

这造成一个纯粹的可理解性问题：**仓库里有 11 处引用 `$prefix/bin/init.sh`，零处生成它的
代码。** 用户被要求 `source` 一个仓库里根本不存在的文件；`Fink::Bootstrap::locate_Fink`
判定「这是不是一个 Fink 安装」时也拿它当条件之一（[Bootstrap.pm:733](../perlmod/Fink/Bootstrap.pm:733)）。
读完整个仓库仍然说不清系统是怎么跑起来的。

现在源码在 [`base-files/`](../base-files/)，来自上游 `fink/base-files` 的
`release_1_9_19` 标签，与 `.info` 里 pin 的版本对应。相对上游只改了两处：示例路径
`/sw` → `/opt/finx`，shell 缩进 2 空格 → 4 空格。行为未动。

**这几个文件是前缀无关的。** `init.sh.in` 里写的是 `BASEPATH` 占位符，由 `setup.sh`
在编译阶段用 `%p` 替换 —— 与仓库根目录那套 `@PREFIX@` 是同一个思路，只是占位符名字不同。

#### 为什么需要打包器，而不是直接引用目录

Fink 的 `find_tarball()` 只认归档文件，且先搜 `$basepath/src`，找到就不下载。所以离线
安装的机制是「把 tar 预先放进 `<prefix>/src`」，由 `Bootstrap::pack_included_sources`
在 `bootstrap2` 里调用 [`base-files/pack.sh`](../base-files/pack.sh) 生成。

难点全在 `.info` 里写死的 `Source-MD5`：tar 是在**用户机器上现场生成**的，字节只要有一点
差异，Fink 就认定下载被篡改并停下来问人。所以 `pack.sh` 抹掉一切随机器变化的量：

| 变量 | 处理 |
| --- | --- |
| `mtime` | `touch` 到固定时刻；`touch -t` 按本地时区解释，所以 `TZ=UTC` 必须钉死 |
| `uid`/`gid` | `--uid 0 --gid 0`，不依赖构建者是谁 |
| `uname`/`gname` | `--uname root --gname wheel` |
| 归档格式 | `--format=ustar`，pax 会写额外扩展头 |
| 成员顺序 | 显式列文件名，不靠目录遍历顺序 |
| gzip 头 | `-n`，不写原始文件名与时间戳 |
| AppleDouble | `COPYFILE_DISABLE=1`，否则 macOS 给带 xattr 的文件塞 `._` 成员 |

实测同一棵树在 `UTC` / `America/New_York` / `Asia/Shanghai` 下产出的 MD5 相同。
跨 `bsdtar` 版本仍可能有差异 —— 那种情况由 `make sources_check` **当场**抓住，
而不是留到 bootstrap 跑到一半才让用户面对一个与他的改动无关的下载错误。
改了 `base-files/` 里的载荷就要 `./base-files/pack.sh --update`。

归档必须有一个 **`base-files-1.9.19/` 顶层目录**，成员全在里面。

这一条我一开始搞反了，写成"必须扁平"，代价是第一次 CI 自举跑到 phase three 就死：

```
/usr/bin/tar --no-same-owner --no-same-permissions -xf /opt/finx/src/base-files-1.9.19.tar.gz
directory /opt/finx/src/finx.build/base-files-1.9.19-1/base-files-1.9.19 doesn't exist,
check the package description
```

原因是 [PkgVersion.pm:1852](../perlmod/Fink/PkgVersion.pm:1852) 的 `get_build_directory`：没有
`SourceDirectory` 也没有 `NoSourceDirectory` 时，子目录名**由 tar 文件名推导**。所以
`base-files-1.9.19.tar.gz` 解出来的东西必须在 `base-files-1.9.19/` 之下，`phase_compile`
才 `chdir` 得进去。上游 SourceForge 上的原始 tar 也是这个布局。

（`finx` 包那个 tar 是扁平的，因为它是 `create_tarball` 直接打的、走 `inject_package`
而不是 `phase_unpack`。两者路径不同，别类推。）

扁平 tar 本身是合法的 gzip+tar，MD5 也自洽，所以**只有自举能发现**，而报错说的是
"package description"，指不到打包脚本。因此 `pack.sh --check` 现在自己断言第一条成员
是 `base-files-<version>/`，把这个不变量钉在会直接失败的地方。

#### 版本与校验和存在哪儿：一个自己制造的事故

第一版把 `Version` 与期望的 MD5 都从 [`10.9-libcxx/base-files.info`](../10.9-libcxx/base-files.info)
读。它读得到 —— 在仓库里。但 `make test` 不止在仓库里跑：`finx` 这个包的
`CompileScript`（[finx.info.in:19](../finx.info.in:19)）里就有 `make test PREFIX=%p ...`，
而它执行时的工作目录是 `create_tarball` 从 `MANIFEST` 打出来、再由 dpkg 解开的那棵树。
那棵树里**没有 `10.9-libcxx/`** —— 它被 `MANIFEST.SKIP` 的 `^10\.[^/]*/` 排除。

于是 `pack.sh --check` 读不到文件，`make sources_check` 失败，`make test` 失败，
finx 包编译失败，**bootstrap 死在 phase 3**。而在仓库里 `make test` 一路是绿的。

修法是把版本与期望 MD5 放进 [`base-files/pack.conf`](../base-files/pack.conf) —— 它随
载荷一起发布，所以在载荷树里也读得到。`.info` 的 `Source-MD5` 仍然存在（Fink 只认它），
但降级为**被交叉校验的一方**：`--check` 在仓库里会确认两者一致，在载荷树里静默跳过
这一半（那儿没有 `.info`）。

这件事的教训不止于 base-files：**凡是被 `MANIFEST.SKIP` 排除的目录，都不能成为构建期
脚本的输入。** 为了不让同类错误再靠人记，加了
[`scripts/payload_test.sh`](../scripts/payload_test.sh)（`make payload_test`）：
把 `MANIFEST` 列出的文件复制到临时目录，在那儿原样跑一遍 `make test`。
它独立于 `make test`（挂进去会在载荷树里递归），由 CI 与 `Verify: all` 调用。

#### 验证到哪一步

已验证：打包可复现（跨时区、跨机器 —— 本机与 GitHub 的 macOS arm64 runner 产出同一个
MD5）、解出来的树能跑通 `setup.sh` + `install.sh`、
生成的 `init.sh` 里前缀展开为 `/opt/finx` 且 `source` 后 `PATH` 正确、
`pack_included_sources()` 确实把 tar 放进 `$basepath/src` 且 MD5 与 `.info` 一致、
`make test` 在**只有 `MANIFEST` 文件的树**里通过。

**未验证：phase three 之后的完整 bootstrap。** 第一次 CI 自举（run 41312771240）证明
phase one 下载与 phase two 编译 —— 包括 dpkg 1.19.7 与 tar 1.29 这两批 2019 年的 C 代码
在 clang 17 + macOS 26 SDK 上 —— 都能过；它死在 phase three 的第一个包（base-files）
解包，原因就是上面那个归档布局错误。修好后重跑前，phase three 的其余 38 个包仍未验证。

`dpkg-base-files` 仍是外部 tarball。它提供的是 `.la` 清理 triggers，不阻塞「系统怎么
跑起来」这个问题，但用的是同一套机制，可以照此办理。

### 8.10 仍待定

| 待定 | 选项 | 影响 |
| --- | --- | --- |
| 兜底是否保留 | 保留自举 / 宁可失败 | 保留则要一直维护两条路径；删除则新 macOS 首发当天无法安装 |

种子分发源已定，不再列出 —— 见 8.8。

---

## 九、测试

套件在 `test/`，Test::Harness 驱动。**基线：56 个测试文件、1192 项断言。**

```
make test        # manifest_check → test_setup → 跑完 test/ 全部测试
```

`make test` 的三个阶段各有分工：

| 阶段 | 作用 |
| --- | --- |
| `manifest_check` | `MANIFEST` 必须列出仓库里每个文件（漏了就不会进发行 tarball），同时 `MANIFEST.SKIP` 必须排除全部生成物 |
| `test_setup` | `./setup.sh test/basepath x86_64`，生成 `finx` / `postinstall.pl` / `lockwait` / `FinkVersion.pm` 等运行时文件 |
| 测试本体 | `cd t && ./testmore.pl && find . -name '*.t' \| sort \| PREFIX=... xargs perl -MTest::Harness` |

维护 `MANIFEST` 的两条经验：

- **要随程序分发的文件必须登记。** 当年的例子是 `readme.de.html`：`install.sh`
  用通配符装 `readme.*.html`，它却漏登记 —— 结果是德文 readme 长期不在发行包里，
  且 `manifest_check` 一直红着，把这条真问题掩盖掉了。那批 HTML 已删（见 10.1），
  但这条规则不受影响。
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

`test/basepath/` 是一套假安装，`PREFIX` 只影响少数用例。

安装器自己的测试走 `FINX_TEST` 沙箱，不碰真实目录：

```
./finx-install/selftest.sh                              # 自建临时根，跑完删除
FINX_TEST=/tmp/finx-check ./finx-install/selftest.sh     # 指定根，保留结果
```

**手工验证安装器时必须带 `FINX_TEST`。** 不带的话默认前缀就是真实的 `/opt/finx`，
会真的往机器上装东西。

### 9.1 CI：一条流水线，就是 `Verify: all` 的线上版

`.github/workflows/verify.yml` 覆盖了 `.vscode/tasks.json` 里 `Verify: all` 的
**全部五步，顺序也一致**，另外加两条只对 CI 有意义的断言（下表的 0 与 6）。
这样本机与线上出结论的地方总是同一处：

| # | 步骤 | 失败意味着 |
| --- | --- | --- |
| 0 | 断言工具链 | runner 换了镜像：`/usr/bin/perl` 低于 5.16，或架构不是 arm64 / x86_64 |
| 1 | `bash -n` 全部 `git ls-files '*.sh'` | 引号或 `if/fi` 不配对 |
| 2 | `make format` | 缩进不合 `STYLE` |
| 3 | `make test_setup` + `perl -c` 全部模块 | 模块有语法错（必须先 test_setup，否则报的是「找不到模块」） |
| 4 | `make test` | 1192 项断言里有失败 |
| 5 | `./finx-install/selftest.sh` | 安装器沙箱的断言里有一条不成立 |
| 6 | `git status --porcelain` 必须为空 | 有生成物没进 `.gitignore`：它会被误提交，或让下次 `manifest_check` 莫名变红 |

三条与"为什么这么设"有关的决定：

- **日常只有一条流水线。** Finx 是公开仓库，GitHub Actions 的标准 runner 对公开
  仓库不计费；CircleCI 的免费层是共享额度、macOS executor 最贵，不该有半份额度花在
  CI 往返上。
- **`.circleci/config.yml` 是备用方案，不是第二条流水线。** 它只在 CircleCI 后台
  Add Project 之后才可能运行，且被 `filters` 限成只认 `ci-*` / `ci-bootstrap-*` 标签。
  其中不复制任何检查逻辑 —— 两边都调 `make` 目标与 `scripts/ci_bootstrap.sh`。
  注意它的 arm64 macOS resource_class 未经核实（查证时 CircleCI 文档全部 404），
  接上之前须自行确认计划是否支持；只有 Intel 可用时，自举产物是 ELF，对 macOS 无用。
- **`concurrency` 开了 `cancel-in-progress`。** 连推几次时，被新提交取代的旧任务
  就地取消，不必等它跑完。
- **一个 job，不做矩阵。** `ARCHITECTURE` 取自 runner 自己的 `uname -m`
  （`test_setup` 会把它写进 `test/basepath`），所以跑的是这台机器的架构，不是
  Makefile 里那个默认的 `x86_64`。要覆盖另一种架构就再加一个 job，别加在同一个
  job 里循环 —— 那样第二次运行会覆盖第一次的 `test/basepath`。

`/usr/bin/perl` 而不是 PATH 上的 `perl`：Makefile 的 `test` 目标与
`test/Services/execute_nonroot_okay.t` 都把它写死了，CI 里做语法检查的也必须是同一个
二进制，否则「查过的」和「跑过的」不是一回事。

---

## 十、已知问题与地雷

| 问题 | 症状 | 状态 |
| --- | --- | --- |
| `manifest_check` 曾经必然失败 | 见 10.1 | **已修** |
| `setup.sh` 变量拼写错误 | 原来第 117 行（现 [118](../setup.sh:118)）把 `$basepath` 写成 `$basepeath`，`compiler_wrapper-10.9` 里的前缀被替换成空串 | **已修**，见 10.2。影响仅限一行注释 |
| phase 2 被执行两次 | [bootstrap:794](../bootstrap) 在错误检查之前多了一次裸的 `execute`，第一次的返回值被丢弃 | **已修**，见 10.3 |
| 两个锁实现不一致 | `lockwait.in` 用可配置的 `pack(@PACKARGS@,…)`，`finx-dpkg-status-cleanup.in` 硬编码 `pack("lllliss",…)`，而文件头写着"KEEP THIS IN SYNC" | **已修**，见 10.4 |
| 三份手写清单互不校验 | `MANIFEST`、`check_files`、`install.sh` 是同一份事实的三个副本 | **已修**，见 10.5 |
| 安装文档版本滞后 | [INSTALL](../INSTALL:3) 是 0.45.6，[Install.md](../Install.md:1) 还是 0.41.1，`VERSION` 已改为 0.1.0-alpha.git | 未修。新文档以本手册为准 |
| `NEWS` 里的旧路径 | 历史条目仍写 `/sw`、`/opt/sw` | 刻意保留，见 [AGENTS.md](../AGENTS.md) |

### 10.1 已修：`manifest_check` 必然失败

原因不止一个，拆开看：

| 症状 | 根因 | 修法 |
| --- | --- | --- |
| `Not in MANIFEST: <文件>` | 该文件确实没登记，而 `install.sh` 的通配符会装上它 —— 当年的 `readme.de.html` 就是这样让**德文 readme 从未进过发行包** | 登记进 `MANIFEST` |
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

这两条规则靠人守是不可靠的——见 10.5。

### 10.2 已修：`setup.sh` 的 `$basepeath`

[setup.sh:118](../setup.sh:118) 把 `$basepath` 拼成了 `$basepeath`。因为 `sh` 不报未定义
变量，`sed -e "s|@PREFIX@|$basepeath|g"` 展开成 `s|@PREFIX@||g`，前缀被替换成空串。

**但它没有功能影响**：`@PREFIX@` 在整个 `compiler_wrapper-10.9.in` 里只出现一次，
在第 25 行那条被 `exec` 挡住的注释中：

```sh
exec $compiler -stdlib=libc++ "$suppress_hard_error" "$@"
# strip path-prefix to avoid finding this wrapper again
# @PREFIX@/bin is needed to pick up ccache-default
```

所以症状只是生成出来的注释写成 `# /bin is needed ...`。修它是为了不留错字，不是因为它在
弄坏构建。判断这类问题要靠 `grep -c '@PREFIX@' <模板>`，不能只看 sed 命令长什么样。

### 10.3 已修：phase 2 被执行两次

[bootstrap:794](../bootstrap) 在错误检查之前多了一次裸的 `&execute($cmd, quiet=>0);`。
`git log -L` 显示这是 `e3efa1a0`（Remove force-depends）的副作用：该提交把注释掉的
错误检查取消注释，但忘了删掉紧邻的旧调用。

代价没有"白跑一遍自举"那么大：`bootstrap-phase2.pl` 只调 `Bootstrap::bootstrap2()`，
后者走 `Engine::cmd_install(@elist, @addlist)`；第二遍会被判定为"已安装"而跳过，不会重新
编译。真正的损失是那行错误检查落在了**第二遍**的结果上——第一遍才是干活的那次。

### 10.4 已修：两个锁实现不一致

`lockwait.in` 与 `finx-dpkg-status-cleanup.in` 的文件头互相要求保持同步，但只有前者用
`@PACKARGS@` 模板，后者硬编码 `pack("lllliss", (0,0), (0,0), 0, F_WRLCK, SEEK_SET)`。

这两个格式**当前恰好等价**，但不是因为它们正确。Perl 的 `l` 是 `long`，实测本机
`length(pack("l",0)) == 4`，于是 `"lllliss"` 也是 8+8+4+2+2=24 字节、字段落在正确偏移。
而 `q` 是恒定 64 位，`"qqiss"` 不随 perl 构建变化——这才是 `lockwait.in` 用 `q` 的原因。
换句话说：**硬编码的那份当时写对了，只是靠了本机 perl 的一个偶然性质。**

修法是把 `packargs` 的定义提到 `finx-dpkg-status-cleanup` 的 `sed` 之前，让两个模板共用
同一个 `@PACKARGS@`：

```sh
# setup.sh，在生成任何 lock 脚本之前
packargs='"qqiss", 0, 0'
```

验证方式（不依赖机器差异）：

```sh
./setup.sh /opt/finx arm64
grep -h 'pack(@\|pack("' dpkg-lockwait finx-dpkg-status-cleanup   # 两行必须逐字相同
```

### 10.5 已修：三份手写清单互不校验

`MANIFEST`（打载荷 tar 用）、`Bootstrap::check_files`（[Bootstrap.pm:665](../perlmod/Fink/Bootstrap.pm:665)，
自举前断言源码树完整）、`install.sh` 的 `for file in ...`（实际安装）**是同一份事实的三个
副本**，手工维护，没有任何交叉检查。`readme.de.html` 那次事故就是三份不同步的产物。

修好 `manifest_check` 只是让其中一份变可靠，不是让三份一致。真正的修法是
[`scripts/structure_test.sh`](../scripts/structure_test.sh)，已挂进 `make test`。

#### 为什么是"执行"而不是"解析"

`install.sh` 的写法是

```sh
for file in update-packages/* ; do
    /usr/bin/install -c -p -m 644 $file "$basepath/lib/finx/update-packages/"
done
```

解析它要重写一遍 shell 的通配符、循环、变量展开规则，而**与真实行为不一致的那一处，
正是 bug 藏身的地方**。所以脚本不解析，而是执行：在临时目录里建两棵树，

| 树 | 内容 |
| --- | --- |
| `tree-git` | 只有 `git ls-files` 列出的文件 |
| `tree-manifest` | 只有 `MANIFEST` 列出的文件 |

各跑一遍 `setup.sh` + `install.sh`，然后 `diff -r` 比对装出来的东西。

两棵树的结果必须完全一致。少了 = MANIFEST 漏登记；多了 = MANIFEST 多登记或
`install.sh` 读了目录里碰巧存在的东西。

另外还有一条**语义断言**：`bin/`、`sbin/` 下的文件必须可执行，`lib/perl5/` 下的模块必须
不带可执行位。这条不能靠两棵树比对来实现 —— 两棵树共用同一个 `install.sh`，把
`-m 755` 写成 `-m 644` 两边会错得一样，比对恒真。所以它检查的是「装出来的东西对不对」，
而不是「两棵树是否一样」。

三条检测路径都做过反向验证：从 `MANIFEST` 里删掉一条 → 报
`Only in tree-git.prefix/share/doc/finx: <那个文件>`；加一条不存在的文件 → 报
"打 tar 时会被静默跳过"；往 `check_files` 里塞一个不存在的名字 → 报"自举会在这里 die"；
把 `install.sh` 里 `$bin` 那行的 `-m 755` 改成 `-m 644` → 逐条列出 `bin/finx` 等七个
文件"没有可执行位"。

不在 git 工作区里运行时（例如从 tarball 解出来的树）跳过双树比对，只做静态检查——
bootstrap 会在那种场景下跑 `make test`，不该因此失败。

#### 顺带纠正：`MANIFEST` 不是发行清单，是载荷清单

一度以为 `check_files ⊆ MANIFEST` 应当成立，而 `finx.info.in` 违反了它。查下来是**理解错了**：

- `finx.info.in` 被 [`MANIFEST.SKIP:18`](../MANIFEST.SKIP:18) 明确排除，是**对的**。
  它不是载荷，是元数据模板：`bootstrap` 从当前目录读它，经 `copy_description`
  生成为包描述，再把 `MANIFEST` 打出来的 tar 填进该描述的 `Source` 字段。
- `check_files` 查的是"源码树是否完整到可以自举"，`MANIFEST` 查的是"载荷 tar 里有什么"。
  两者本来就不同集，套用同一条包含关系是错的。

这就是第 8.7 节「一个概念四个名字」的另一种形态：**两个名字听起来是同一件事
（"清单"），实际是两个不同的集合。** `10.9-libcxx/` 与 `mirror/` 同样只被
`MANIFEST.SKIP` 排除、不进载荷 tar，理由相同。

### 10.6 已补：载荷的符号链接能逃出前缀

解包工具只过滤成员**名字**里的 `../`，与链接的**目标**无关。于是一个载荷可以
老实躺在树内、指向任何位置：

```
lib/innocent.dylib -> /Users/someone/.ssh/id_rsa
```

装完之后，任何顺着它去读或去写的代码都落到树外 —— `resign_macho` 会走遍整棵树、
`scanpackages` 会执行树里的 `bin/finx`、卸载时的 `rm -rf` 会顺着它出去。而 dpkg
的 `postinst` 本来就是真 root。

规则：**一个载荷自带的符号链接，解析后必须落在安装根目录内，或落在豁免的系统
位置，否则拒绝安装。** 判定按**路径分段**比较，不是字符串前缀 —— `/opt/finx2`
不是 `/opt/finx` 的子目录，`/usrlocal` 也不是 `/usr`。

豁免只有八处，两条理由必须同时成立才开口子：

```
/bin   /sbin   /usr/bin   /usr/sbin   /usr/lib   /usr/libexec
/System   /Library/Apple
```

1. **SIP 保护。** 连 root 都写不进去，"顺着链接去写"不成立；上游产物里本来就有
   指向 `/usr/bin` 的正常引用。
2. **不含隐私文件。** 那里只有系统自带的二进制与库，"顺着链接去读"也不成立。

其余一律不例外：`/Users`、`/Library` 里 `Apple/` 以外的部分、`/private`、`/opt`、
`/etc`、`/var` 都有用户数据，且大多不受 SIP 保护。

三个出口，两套实现，**豁免表必须一致**：

| 出口 | 实现 | 检查时机 |
| --- | --- | --- |
| 种子安装器（`curl \| bash`） | [`finx-install/install.sh`](../finx-install/install.sh) | 解包之后、`resign_macho` 之前；拒绝时清空前缀内容 |
| `finx install` 装 `.deb` | [`perlmod/Fink/Links.pm`](../perlmod/Fink/Links.pm) `offending_in_deb` | `dpkg -i` 之前，解析 `dpkg-deb -c`，不额外解包 |
| 构建出的前缀 | 同上 `offending_in_tree`，挂在 `make structure` | 装完立即查，早于打包 |

两个实现都做**词典序**归一化，不碰文件系统：悬空链接同样判定 —— 一个指向
`/opt/nothing-here` 的悬空链接，等那个路径出现时就变成真越界。

解析 `dpkg-deb -c` 时按**第一个** ` -> ` 切，不是最后一个：产物文件名不可能含
箭头，目标却可能；按最后切会让 `-> /usr/local/t -> y` 的目标被看成无害的相对
`y` 而放行。

已知边界：检查发生在解包之后，所以越界链接会短暂存在于目标目录里（随后被删除）。
真正危险的是"顺着它写"与"顺着它读"，两者都要等落盘之后才可能发生。
