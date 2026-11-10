# Finx 结构导览

这份文档回答三个问题：

1. **常见操作时，代码实际做了什么**（按执行顺序，不是按文件名）
2. **仓库里的文件各自负责什么**
3. **装完之后 `/opt/finx` 里为什么会是那个样子**

它不解释*为什么*这么设计 —— 那是 [`TECHNICAL-GUIDE.md`](./TECHNICAL-GUIDE.md) 的活。

---

## 零、先分清两棵树

这是读这份代码最容易混的地方。

| | 源码树 | 安装树 |
| --- | --- | --- |
| 在哪 | 你 `git clone` 下来的目录 | `/opt/finx` |
| 里面是什么 | `bootstrap`、`perlmod/Fink/*.pm`、`*.in` 模板、包描述 | 展开后的 `finx` 可执行文件、`.pm` 模块、dpkg 数据库、下好的源码 |
| 谁写进去 | 你 | `install.sh` 与 `dpkg` |
| 有 `.in` 后缀的东西 | 有 | **没有**（`setup.sh` 已经把它们展开） |

**Finx 是自举的**，所以同一个程序在两棵树里各存在一次：

```
源码树里的 perlmod/Fink/Engine.pm
   ↓ setup.sh 展开模板、install.sh 拷进去
安装树里的 /opt/finx/lib/perl5/Fink/Engine.pm
   ↓ 被 /opt/finx/bin/finx 加载
用来装别的包
```

`./bootstrap` 做的全部事情，就是**把源码树变成安装树，顺便用它把 dpkg 和一批基础包也装进去**。

---

## 一、`./bootstrap /opt/finx` —— 从零装一个 Finx

这是最复杂的一条路径。按实际执行顺序：

### 第 1 步：提权与环境判定

```
你运行 ./bootstrap /opt/finx
  → 不是 root？弹菜单让你选 sudo/su（选完重新执行自己，参数前面加 .sudo）
  → 检查 cc / make / head / pod2man
  → 检查 Xcode 版本在允许区间内
  → ./update/config.guess 得到 aarch64-apple-darwin24.5.0
  → Fink::Bootstrap::check_host() 把它映射成 Distribution: 15.0
```

对应代码：`bootstrap` 前 400 行 + [`perlmod/Fink/Bootstrap.pm:167`](../perlmod/Fink/Bootstrap.pm:167) 的 `check_host`。

> `Distribution` 决定用哪一份包描述。现在所有 Darwin ≥ 13 的系统都映射到 `15.0` 或更晚，而这些又全部指向同一棵 `10.9-libcxx` 树 —— 所以那张表里 16 个发行版其实只对应 1 棵真实的树。

### 第 2 步：建骨架、写配置、交互

```
mkdir /opt/finx/{etc,src,finx,var,var/lib/finx}
写 /opt/finx/etc/finx.conf（Basepath / RootMethod / Trees / Distribution / SelfUpdateTrees）
Fink::Configure::configure()   ← 你回答的那一串问题
```

[`perlmod/Fink/Configure.pm`](../perlmod/Fink/Configure.pm) 负责这些提问：`FetchAltDir`、`Buildpath`、`UseBinaryDist`、build user、verbosity、代理、并行数、镜像。

> 每个问题读到 EOF 就取默认值 —— 这就是 `stdin < /dev/null` 能实现无人值守的原因。

### 第 3 步：把源码树打成 tar

```
Fink::Bootstrap::fink_packagefiles()   ← 读 MANIFEST，列出要打进去的文件
Fink::Bootstrap::create_tarball()      ← tar -cf /opt/finx/src/finx-1.0.0-beta4.tar <那些文件>
```

**注意这个 tar 是扁平的**（成员在顶层，没有 `finx-1.0.0-beta4/` 目录）。它走的是后面的 `inject_package`，不经过 `phase_unpack`，所以规则不同。

### 第 4 步：生成 finx 自己的包描述

```
Fink::Bootstrap::copy_description()
  finx.info.in  →  /opt/finx/finx/dists/stable/main/finkinfo/base/finx-15.0.info
  填上 %v/%r（版本/修订号），Source 指向第 3 步那个 tar
```

### 第 5 步：phase one —— 下载

```
Fink::Bootstrap::pack_included_sources()   ← 先打 base-files 的 tar 放进 /opt/finx/src
Fink::Engine::cmd_fetch_missing(...)       ← 再下载其余 essential 包的源码到 /opt/finx/src
```

`find_tarball` 先搜 `$basepath/src`，所以已经在里面的不会被下载。

**这是整条链路里唯一会联网取 essential 包的地方**，也是为什么 `pack_included_sources` 必须放在这一步之前。

### 第 6 步：phase two —— 无包管理器编译出 dpkg

```
Fink::Bootstrap::bootstrap1()
  tar-bootstrap、dpkg-bootstrap 各自:
    phase_unpack → phase_patch → phase_compile → phase_install
  装进 /opt/finx/bootstrap/（一个临时树，不是正式前缀）
```

这一步**必须真的编译 C 代码**，因为此时还没有 dpkg 可以装 `.deb`。

### 第 7 步：phase three —— 用刚编出来的 dpkg 装 39 个包

```
Fink::Bootstrap::bootstrap2()
  Fink::Engine::cmd_install(那 39 个包)   ← 完全走正常的装包流程（见第二节）
```

装的东西包括 `base-files`、`dpkg`、`finx`（自己）、`bzip2`、`gettext`、`ncurses`、`tar`、`xz`……

**`finx` 这个包自己走的是 `inject.pl` → `inject_package()`**，不是 `phase_unpack`。这是第 3 步那个扁平 tar 能用的原因。

### 第 8 步：收尾

```
Fink::Bootstrap::bootstrap3()   ← rm -rf /opt/finx/bootstrap
提示你 . /opt/finx/bin/init.sh
```

---

## 二、`finx install foo` —— 装一个包

这条路径由 [`perlmod/Fink/PkgVersion.pm`](../perlmod/Fink/PkgVersion.pm) 的 `phase_*` 系列函数串起来，`Engine.pm` 的 `cmd_install` 调用它们。

| 顺序 | 函数 | 做什么 | 产物 |
| --- | --- | --- | --- |
| 1 | `phase_fetch` | 按 `Source:` 从镜像下载 | `/opt/finx/src/foo-1.0.tar.gz` |
| 2 | （校验） | 比对 `.info` 里的 `Source-MD5` / `Source-Checksum` | 不符就弹菜单问怎么办 |
| 3 | `phase_unpack` | 解包到 `$basepath/src/finx.build/foo-1.0-1/foo-1.0/` | 展开后的源码树 |
| 4 | `phase_patch` | 依次跑 `PatchScript` 或 `patch < PatchFile` | 打过补丁的源码 |
| 5 | `phase_compile` | 跑 `CompileScript`（`./configure && make`） | 编译产物 |
| 6 | `phase_install` | 跑 `InstallScript`，装到假根 `%i` | `.../foo-1.0-1/foo-1.0/root/` |
| 7 | （打包） | `dpkg-deb -b` 封成 `.deb` | `/opt/finx/finx/15.0/main/binary-darwin-arm64/` |
| 8 | （链接） | 在 `/opt/finx/finx/debs/` 建符号链接 | 指向第 7 步的实物 |
| 9 | （安装） | `dpkg -i` 把 `.deb` 装进 `/opt/finx` | 文件落到正式位置 |
| 10 | `phase_activate` | 跑 `PostInstScript`、注册到 dpkg 数据库 | 可用了 |

**第 3 步有个坑**：解包后的目录名默认**由 tar 文件名推导**（`foo-1.0.tar.gz` → `foo-1.0`），除非 `.info` 里写了 `SourceDirectory` 或 `NoSourceDirectory`。打包时布局错了，报错会说"package description 有问题"，指不到打包脚本。

同一个包可以有多个 `SplitOff`（例如 `bzip2` 拆出 `bzip2-shlibs`、`bzip2-dev`），它们共用一次编译。

---

## 三、其他常见操作

### `finx selfupdate`

```
Fink::SelfUpdate::<方法>::update()   ← rsync / git / cvs / svn 之一
  把包描述树同步到 /opt/finx/finx/10.9-libcxx/
  → finx index               重建 /opt/finx/var/lib/finx/index.db
  → finx scanpackages        刷新 binary-*/Packages 索引
```

包描述**不是**随 finx 一起装的，是这一步单独拉的 —— 所以刚装完的 finx 只有一个 `base` 目录能装东西。

### `finx install --dry-run`

解依赖、把「会装什么、从哪儿取」打出来，然后在编译/安装之前返回。不写这个开关
的话，想看一眼依赖树就只能真装一遍。

它走的是 `real_install` 的第四个参数：打印用 `would be` 的时态、跳过确认提问、
`prefetch` 只做 dry-run 的取用（源码就是列出候选镜像与校验值，二进制包交给
`apt-get --dry-run`），最后 `return if $fetch_only || $dryrun` 停在构建之前。

```
$ finx install --dry-run cvs
The following package would be installed or updated:
 cvs
cvs-1.12.13.tar.bz2 md5=956ab476... <三个候选镜像> <维护者>
```

`-n` 是它的短写法。注意 `get_options` 用 `require_order`，所以旗标要写在包名前面。

### `finx list` / `describe` / `show-deps`

只读操作。`list` 读 `index.db`；`describe` 读 `.info`；`show-deps` 走 `Package.pm` 的依赖求解。

### `finx remove` / `purge`

`phase_deactivate`（跑 `PreRmScript`、从 dpkg 数据库注销）→ `dpkg -r`。`purge` 额外调 `phase_purge` 删残留配置。

### `finx-install/install.sh`（新安装器，与 `bootstrap` 是两条独立路径）

```
resolve_method()   决定走种子还是源码
  ├ seed    下载预编译种子 → 解压 → dpkg -i  → 一分钟
  └ source  回落到 ./bootstrap 的那条路      → 十几分钟起
```

---

## 四、仓库结构

### 根目录：程序本体

| 文件 | 作用 | 会被装进前缀吗 |
| --- | --- | --- |
| `bootstrap` | **唯一安装入口**。判定环境 → 建目录 → 打 tar → 三阶段自举 | 是（进 tar） |
| `bootstrap-phase2.pl` | 被 `bootstrap` 重新执行的第二阶段脚本，薄薄一层，只调 `Bootstrap::bootstrap2()` | 是 |
| `setup.sh` | **模板展开器**。把 `*.in` 里的 `@PREFIX@`/`@ARCHITECTURE@`/`@VERSION@` 换成真值 | 是 |
| `install.sh` | **本包的安装阶段脚本**。建目录、拷文件到 `%i` | 是 |
| `inject.pl` | 把当前源码树当成一个包注入进已有安装（`finx` 自己就是这么装的） | 是 |
| `finx.in` → `finx` | 主程序启动器（`use lib "@BASEPATH@/lib/perl5"`，加载 `Fink::Engine`） | 展开后装到 `bin/` |
| `finx-virtual-pkgs.in` | 生成虚拟包（`system-*` 之类），让包描述能 Depends 系统能力 | 展开后装到 `bin/` |
| `finx-instscripts.in` | 从包里抽出安装脚本 | 展开后装到 `bin/` |
| `finx-scanpackages.in` | 生成 `Packages` 索引 | 展开后装到 `bin/` |
| `finx-dpkg-status-cleanup.in` | 清理 dpkg 状态文件里的残留条目 | 展开后装到 `sbin/` |
| `lockwait.in` | 包一层 dpkg lock，等锁而不是直接失败 | 展开成 `dpkg-lockwait`、`apt-get-lockwait` |
| `pathsetup.sh.in` | 帮用户把 `init.sh` 写进 shell 启动文件 | 展开后装到 `bin/` |
| `compiler_wrapper-10.*.in` | 不同 Xcode 时代的编译器包装（加 `-stdlib=libc++`、处理告警） | 展开后装到 `var/lib/finx/path-prefix-*/` |
| `g++-wrapper.in` | 老的 g++ 包装 | 同上 |
| `postinstall.pl.in` | 装完包之后跑的后处理 | 展开后装到 `lib/finx/` |
| `shlibs.default.in` | shlibs 默认值 | 展开后装到 `etc/dpkg/` |
| `finx.8.in` / `finx.conf.5.in` | man 页 | 展开后装到 `share/man/` |
| `finx.shlibs` | shlibs 数据 | 装到 `%d/DEBIAN/shlibs` |
| `pre-build-test.sh` | 检查 `pod2man` 存在，缺了就别往下走 | **finx 包的 `CompileScript` 第一步** |
| `Makefile` | `make test` / `format` / `structure` / `sources_check` / `payload_test` | 否 |
| `MANIFEST` | **载荷清单**：打包 tar 时装哪些文件 | 它自己也在里面 |
| `MANIFEST.SKIP` | 打包时**排除**哪些（生成物、``^10\.[^/]*/``、`mirror/` 等） | 否 |
| `VERSION` / `REVISION` | 版本号 / 每个发行版的修订号。两者的取用规则见 TECHNICAL-GUIDE 2.1 | 是 |
| `Release` | apt 索引模板 | 是 |
| `STYLE` | 2003 年的 Perl 代码风格原文 | 是（历史文档） |
| `NEWS` / `AUTHORS` / `COPYING` / `COPYING-zh` / `LICENSE` / `LICENSE-zh` / `README*` / `INSTALL*` / `USAGE*` / `TODO` | 历史文档与许可文件，随包分发。`*-zh` 是中文参考译本，法律效力以英文原文为准 | 是 |

### `perlmod/`：全部 Perl 模块（48 个文件）

装到 `/opt/finx/lib/perl5/`。按职责分：

| 模块 | 行数 | 干什么 |
| --- | --- | --- |
| `PkgVersion.pm` | 6646 | **单个包的单个版本**。所有 `phase_*` 都在这；依赖求解、`.info` 解析、打包、装包 |
| `Engine.pm` | 3544 | **命令分发**。`finx install` 等子命令的入口（`cmd_*`） |
| `Services.pm` | 2767 | 杂项系统服务：执行命令、比较版本号、处理文本、`%` 展开、锁、选项解析（`get_options`） |
| `Validation.pm` | 2557 | `.info` 字段校验（含"不许硬编码前缀"那条） |
| `VirtPackage.pm` | 2484 | 虚拟包：把系统能力（SDK、perl、openssl…）伪装成包 |
| `Package.pm` | 1363 | 所有包的集合：索引、查找、`Essential` 判定 |
| `Config.pm` | 1266 | `finx.conf` 读写 + 路径推导（`$basepath`/`$buildpath`/`$dbpath`…） |
| `Bootstrap.pm` | 1195 | 自举三阶段、`check_host`、打 tar、`inject_package` |
| `SysState.pm` | 997 | 探测系统状态（架构、SDK 路径等） |
| `CLI.pm` | 867 | 与用户交互：提问、进度条、`print_breaking`（带颜色标记时转入 `Fink::Color` 折行） |
| `Configure.pm` | 768 | `finx configure` 的那一串问题 |
| `Scanpackages.pm` | 671 | 纯 Perl 的 `.deb` 扫描器，生成 `Packages` |
| `SelfUpdate.pm` | 553 | 更新包描述树（命令分发到 `SelfUpdate/*.pm`） |
| `NetAccess.pm` | 475 | 下载（curl/axel/wget 后端） |
| `Mirror.pm` | 434 | 镜像列表解析：`mirror:gnu:` 这类写法展开成真 URL |
| `Command.pm` | 417 | 用 Perl 模拟 `cat`/`cp`/`mkdir_p`/`rm_rf` 等 |
| `Help.pm` | 595 | `--help` 的渲染：展开 `helpformat` 模板、折行、按角色上色 |
| `Notify.pm` | 355 | 带外通知（Growl / Syslog / XTerm / Say） |
| `Color.pm` | 430 | 唯一的调色板 `%PALETTE`、`${name}` 标记，以及 `==>` 的颜色角色 |
| `Domains.pm` | 400 | 所有对外地址的唯一来源（`FINX_*_DOMAIN` / `FINX_MIRROR_DOMAIN` 基址 → 内置默认） |
| `Base.pm` | 286 | 最基础的参数处理基类 |
| `Checksum.pm` | 253 | MD5 / SHA1 / SHA256 |
| `Finally.pm` | 226 | 作用域结束自动清理（类似 RAII） |
| `Status.pm` | 224 | dpkg 状态文件读写 |
| `FinkVersion.pm.in` | — | 版本 + 架构 + `get_arch()`，由 `setup.sh` 展开 |
| `Fink.pm.in` | — | 顶层命名空间，由 `setup.sh` 展开 |

子目录：

| 目录 | 内容 |
| --- | --- |
| `Fink/SelfUpdate/` | `Base.pm` + `rsync` / `git` / `cvs` / `svn` / `point` 五种更新后端 |
| `Fink/Checksum/` | `MD5` / `SHA1` / `SHA256` 实现 |
| `Fink/Notify/` | `Growl` / `QuickSilver` / `Say` / `Syslog` / `XTerm` |
| `Fink/Finally/` | `Buildlock`（构建锁）/ `BuildConflicts`（冲突检查） |
| `Fink/Text/` | `DelimMatch` / `ParseWords`（CPAN 派生） |
| `Fink/Tie/` | `IxHash`（有序哈希，CPAN 派生） |

### `10.9-libcxx/`：**唯一的**包描述树（40 个文件）

`.info` 是包描述，`.patch` 是源码补丁。这里只有 `stable/main/finkinfo/base/` 那一层的东西 —— 也就是自举和核心包。

**注意：这个目录不进载荷 tar**（被 `MANIFEST.SKIP` 的 `^10\.[^/]*/` 排除），它是运行期 `cp` 到 `/opt/finx/finx/dists/...` 的。

### `mirror/`：镜像列表（18 个文件）

`mirror:gnu:`、`mirror:sourceforge:` 这类写法在这里展开成候选 URL 列表。同样不进载荷 tar。

### `base-files/`：内置的基础包源码（13 个文件）

`Essential: yes` 的目录骨架包。以前在 SourceForge 上，现在收进来了。

| 文件 | 作用 |
| --- | --- |
| `init.sh.in` / `init.csh.in` | **`init.sh` 的来源** —— 用户要 `source` 的那个 |
| `setup.sh` | 展开 `BASEPATH` 占位符 |
| `install.sh` | 建目录、拷文件 |
| `pager.in` / `editor.in` | `$PAGER` / `$EDITOR` 的兜底包装 |
| `dir-base` | `share/info/dir` 的初始内容 |
| `pack.sh` | **确定性打包器**，见下 |
| `pack.conf` | 版本 + 期望 MD5（随载荷发布，所以载荷树里也读得到） |
| `COPYING` / `NEWS` / `README` | 上游文档（`base-files/COPYING` 是载荷的一部分） |

`pack.sh` 把源码打成 `base-files-<ver>.tar.gz`，要求**跨机器逐字节可复现**（钉死 mtime/uid/gid/格式/顺序/gzip 头），因为 `.info` 里的 `Source-MD5` 是写死的。

### `finx-install/`：面向用户的新安装器（11 个文件）

| 文件 | 作用 |
| --- | --- |
| `install.sh` | 入口：解析参数 → `resolve_method` → 走种子或源码 |
| `install.sh` | **唯一源文件**，约 2000 行。日志与 `die`、探测 arch / macOS、拉种子清单并校验 sha256、解压与 `dpkg -i`、源码回落（取源码包、检查前置、跑 `./bootstrap`）全在里面。用户 `curl \| bash` 的就是它 |
| `selftest.sh` | 沙箱断言，全程离线 |
| `seed/manifest.example` | 种子清单样例 |
| `README.md` | 设计与未做项 |

### `scripts/`：仓库自身的守卫与发布工具（5 个，都不是运行时）

| 脚本 | 守住什么 |
| --- | --- |
| `format_check.pl` | Perl 用 tab、shell 用 4 空格 |
| `structure_test.sh` | 建两棵树（git 清单 / MANIFEST 清单）各装一遍，结果必须逐字节一致；外加 `.gitignore` 与 `MANIFEST.SKIP` 必须配对 |
| `payload_test.sh` | 在**只有 MANIFEST 文件**的树里跑 `make test` —— 那就是 finx 包 `CompileScript` 的真实环境 |
| `make_seed.sh` | 不是守卫，是发布工具：把装好的前缀打成种子并写出清单（详见 `TECHNICAL-GUIDE.md` 8.3） |
| `seed_test.sh` | 打包器 → 安装器的往返：剔掉的确实不在、该留的确实在、装出来的 `finx.conf` 指向实际前缀 |

### 其他

| 路径 | 作用 |
| --- | --- |
| `test/`（67 个） | Perl 测试套件，48 个 `.t` 文件 |
| `docs/` | 本文档与 `TECHNICAL-GUIDE.md` |
| `update/`（5 个） | `config.guess` / `config.sub` / `ltmain.sh` 等，供包构建用 |
| `update-packages/` | `finx selfupdate-packages` 用的脚本 |
| `images/`（8 个） | 通知用的图标 |
| `.github/workflows/` | `verify.yml`（每次推送）+ `bootstrap.yml`（手动触发的真自举） |
| `.vscode/` | 任务定义（`Verify: all` 等） |

---

## 五、装完之后 `/opt/finx` 长什么样

| 路径 | 里面是什么 | 谁写的 |
| --- | --- | --- |
| `bin/` | `finx`、`finx-virtual-pkgs`、`finx-scanpackages`、`init.sh`、`pathsetup.sh`、`-lockwait` | `install.sh` / `base-files` |
| `sbin/` | `finx-dpkg-status-cleanup`、`dpkg` | `install.sh` / `dpkg` 包 |
| `lib/perl5/` | 全部 `Fink::*` 模块 | `install.sh` |
| `lib/perl5/darwin/` | 架构相关模块 | 各包 |
| `lib/finx/` | `postinstall.pl`、`update/`、`update-packages/` | `install.sh` |
| `etc/` | `finx.conf`（**主配置**）、`dpkg/`、`profile.d/` | `bootstrap` / `dpkg` |
| `share/` | man 页、文档、图标、`info/dir` | 各包 |
| `var/lib/finx/` | `index.db`（包索引）、`path-prefix-*/`（编译器包装） | `finx index` |
| `var/lib/dpkg/` | dpkg 数据库：`status`、`status-finx`、`info/` | `dpkg` |
| `var/run/finx/buildlock/` | 构建锁 | `Finally::Buildlock` |
| `src/` | 下好的源码 tar + `finx.build/`（解包与编译工作区） | `finx fetch` / `phase_unpack` |
| `finx/dists/` | 包描述树（`10.9-libcxx/`、`local/`、符号链接 `15.0`） | `finx selfupdate` |
| `finx/15.0/main/binary-darwin-arm64/` | **编好的 `.deb` 实物** + `Packages` 索引 | `dpkg-deb -b` |
| `finx/debs/` | 指向上面那些 `.deb` 的**符号链接** | 打包后建链 |

`finx.conf` 里的关键键：

| 键 | 含义 | 默认 |
| --- | --- | --- |
| `Basepath` | 安装根 | `/opt/finx` |
| `Distribution` | 发行版 | 由 `check_host` 决定，如 `15.0` |
| `Architecture` | 架构 | `arm64` / `x86_64` |
| `Trees` | 启用哪些描述树 | `local/main stable/main` |
| `Buildpath` | 编译工作区 | `$basepath/src/finx.build` |
| `FetchAltDir` | 额外的 tar 缓存目录 | 空 |
| `UseBinaryDist` | 是否优先用 `.deb` | 仅当前缀是 `/opt/finx` |
| `MirrorOrder` / 各 `Mirror-*` | 镜像偏好 | — |

`Config.pm` 推导出的三个路径：

```
$buildpath = $basepath/src/finx.build     编译在哪里发生
$libpath   = $basepath/lib/finx           运行期数据
$dbpath    = $basepath/var/lib/finx       索引与锁
```

---

## 六、"我要改 X，该动哪个文件"

| 想做的事 | 动这里 | 之后要跑 |
| --- | --- | --- |
| 新增 `finx` 子命令 | `Engine.pm` 的命令表 + `cmd_*` | `make test` |
| 改包描述语法的校验 | `Validation.pm` | `make test` |
| 改装包流程的某个阶段 | `PkgVersion.pm` 的 `phase_*` | `make test` |
| 改自举流程 | `bootstrap` + `Bootstrap.pm` | `make bootstrap` 实测 |
| 新增虚拟包 | `VirtPackage.pm` | `make test` |
| 改某个核心包怎么编 | `10.9-libcxx/<包>.info` | `make test`，必要时改 `.patch` |
| 改 `init.sh` 的内容 | `base-files/init.sh.in` | **`./base-files/pack.sh --update`** |
| 改内置源码包的打包方式 | `base-files/pack.sh` | `--update` + `make sources_check` |
| 新增要随程序分发的文件 | `MANIFEST` | `make manifest_check` |
| 新增生成物 | **同时**改 `MANIFEST.SKIP` 与 `.gitignore` | `make structure` |
| 改面向用户的安装器 | `finx-install/install.sh` | `./finx-install/selftest.sh` |
| 只改文档 | `docs/`、`*.md` | 无（`.md` 不打包） |

---

## 七、三条容易踩的边界

1. **`MANIFEST` 是载荷清单，不是发行清单。** `10.9-libcxx/`、`mirror/`、`finx-install/`、所有 `.md` 都被 `MANIFEST.SKIP` 刻意排除 —— 它们由运行期单独 `cp` 或干脆不装，不是"漏登记"。

2. **`install.sh` 是包内脚本，不是用户安装器。** 用户安装器在 `finx-install/`。改名 `install.sh` 要同时改 `MANIFEST`、`Bootstrap::check_files`、`inject.pl` 和外部 tarball，做不全就装不上。

3. **生成物必须同时在 `.gitignore` 和 `MANIFEST.SKIP` 里。** 只加一处：加在 `.gitignore` → `make test` 会在下次自举后突然变红；加在 `MANIFEST.SKIP` → 文件会被误提交。`make structure` 现在会检查这一对。
