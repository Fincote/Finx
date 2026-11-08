# 镜像与下载源环境变量

Finx 安装器不读任何配置文件，也不用命令行参数来定位镜像。**全部通过环境变量控制**，
每一个都有内置默认值，全部不设即走官方。

这份文档只讲环境变量这一层。安装流程本身见
[finx-install/README.md](../finx-install/README.md)。

---

## 一、一张表

| 变量 | 默认值 | 覆盖什么 |
| --- | --- | --- |
| `FINX_INDEX_DOMAIN` | 不设则用 GitHub Releases 的 `seed` 标签 | 种子**清单**：`<域名>/manifest` |
| `FINX_SEED_DOMAIN` | `https://finx.sh/finx/seed` | 清单里没写 `url` 时的种子**归档**：`<域名>/<文件名>` |
| `FINX_SOURCE_DOMAIN` | `https://codeload.github.com/Fincote/Finx` | 源码归档：`<域名>/tar.gz/<ref>` |
| `FINX_SEED_BASE` | `https://github.com/Fincote/Finx/releases/download` | 种子的基址：`<基址>/seed-<Darwin>/manifest` |
| `FINX_LOWEST_SEED_DARWIN` | `21` | 往下找种子时试到哪一档为止 |
| `FINX_DEB_DOMAIN` | `https://github.com/Fincote/debs/releases/download` | 预编译 `.deb`：`<域名>/<包名>/<包名>@<版本>-<修订>.darwin<Darwin>-<架构>.deb` |
| `FINX_SOURCE_REF` | `main` | 源码的分支/标签/提交，等同 `--ref` |
| `FINX_CONNECT_TIMEOUT` | `30` | 连不上的等待秒数。**只管连接**，不管下完要多久 |
| `FINX_DEFAULT_MANIFEST_URL` | 见下面的优先级 | 直接给出清单的完整 URL，绕过上面的拼装 |
| `FINX_MANIFEST_URL` | 空 | 等同 `--manifest-url`：显式指定清单，且**不回落**源码 |

`finx` 自己（不是安装器）另有一组，全部在 `finx mirror` 里可见。它们由
`Fink::Domains` 统一解析，**只有环境变量与内置默认两个来源** —— 以前还有第三
个来源（`lib/finx/mirror/` 与 `lib/finx/URL/` 下那批单行文件），那种间接层最
安静的死法是数据过期而代码已改对，于是旧地址赢，所以整个去掉了。

| 变量 | 默认值 | 覆盖什么 |
| --- | --- | --- |
| `FINX_API_DOMAIN` | 空（尚未搬过来） | 包描述树（infosource） |
| `FINX_DEB_DOMAIN` | `https://github.com/Fincote/debs/releases/download` | 预编译 `.deb`，按 `<域名>/<包名>/<文件>` 取 |
| `FINX_SOURCE_DOMAIN` | `https://codeload.github.com/Fincote/Finx` | finx 自身源码归档 |
| `FINX_SOURCECODE_DOMAIN` | `https://github.com/Fincote/Finx-source/releases/download/src-1` | 上游源码池（`.info` 里 `CustomMirror` 指向的那批） |
| `FINX_SELFUPDATE_DOMAIN` | 空（尚未搬过来） | 自更新数据 |
| `FINX_MIRROR_DOMAIN` | 空 | 基址：一次覆盖上面全部，地址为 `<基址>/<kind>` |

`FINX_DEB_DOMAIN` 与 `FINX_SOURCE_DOMAIN` 安装器也读，所以两边填同一个值即可。

**这五个是否真的生效**：`FINX_SOURCECODE_DOMAIN` 会替换 `.info` 里指向官方池
的那串地址（只换那一串，包自己的 `Secondary` 保留）；`FINX_MIRROR_DOMAIN`
派生出的同一个值也一样。其余四个目前仍只在 `finx mirror` 里显示，真正的取用方
（apt 那条通道、selfupdate 的下载）还没接上来。

**提权之后还在不在**：`finx install` / `fetch` / `build` 会以 root 重新执行
自己，这些变量由 `Fink::Engine::root_env_prefix()` 显式转发过 `sudo`。往
`Fink::Domains` 加新变量时必须同步 `Engine.pm` 的 `@ROOT_ENV_VARS`。

代理相关（不是 Finx 发明的，`curl` 与 `sudo` 都认）：

| 变量 | 说明 |
| --- | --- |
| `https_proxy` / `http_proxy` / `all_proxy` | 出网代理，`curl` 自动读取 |
| `no_proxy` | 不走代理的主机 |
| 大写的同名变量 | 同样支持；大小写两套都会被转发给 sudo |

---

## 二、优先级

清单地址按下面的顺序确定，**先命中先赢**：

```
1. --manifest-url=URL  /  FINX_MANIFEST_URL    显式给出，且不回落源码
2. --seed-dir=DIR                              用本地目录里的 manifest
3. FINX_DEFAULT_MANIFEST_URL                   完整 URL，直接覆盖
4. FINX_INDEX_DOMAIN 已设 → <该域名>/manifest   只换域名
5. 都不设 → GitHub Releases 的 seed 标签        官方默认
```

第 4 与第 5 条的区别是刻意的：`FINX_INDEX_DOMAIN` **设了才算覆盖**。这样
`finx.sh` 将来接管默认地址时，用户不需要改任何东西，而已经自己配了镜像的人
也不会被悄悄改回去。

一个容易看错的地方：`FINX_INDEX_DOMAIN` 自己的回落值是
`https://finx.sh/finx/seed`，但**不设它**时生效的清单地址是 GitHub Releases。
「没有这个变量」和「这个变量等于官方域名」在当时是同一件事，将来则不是 ——
前者会跟着默认值走，后者钉死在 finx.sh。

---

## 二点五、`finx mirror`：现在到底用的哪个地址

装了镜像之后最想知道的是「这次用的是镜像还是官方地址」。以前只能 `echo` 一堆
环境变量自己分辨；现在：

```
$ finx mirror
Mirror configuration

  api         FINX_API_DOMAIN         unset    (not configured)
  bottle      FINX_DEB_DOMAIN         env      https://user:******@mirror.example.top/Finx/bottle (auth)
  core        FINX_SOURCE_DOMAIN      default  https://codeload.github.com/Fincote/Finx
  sourcecode  FINX_SOURCECODE_DOMAIN  default  https://github.com/Fincote/Finx-source/releases/download/src-1
  selfupdate  FINX_SELFUPDATE_DOMAIN  unset    (not configured)
```

`source` 一列是四态：`env`（你设了这个 kind 自己的变量）、`base`（由
`FINX_MIRROR_DOMAIN` 派生）、`default`（内置地址）、`unset`（这块内容还没有
固定地址）。未设置也打印默认值 —— 空值看不出「没设」还是「设成了空」。

| 旗标 | 作用 |
| --- | --- |
| `--json` | 同一份数据，字段化 |
| `--raw` | 可直接粘贴的 `export` 行（`--only-set` 只导出你改过的） |
| `--show-password` | 打印真实密码；默认固定六个星号，与长度无关 |
| `--hide-user` | 连用户名一起打码 |

两条安全约定：密码默认打码，`--raw` 在打码时会在末尾提示加 `--show-password`
（否则那几行贴进 shell 是连不上的）；日志与错误信息里的地址一律走
`Fink::Domains::redact_url`，因为那些输出会被贴进 issue。

`--json` 与 `--raw` 互斥，同时给会直接报错，不让人靠猜。

---

## 三、常见用法

### 只想用国内镜像

```sh
export FINX_INDEX_DOMAIN=https://mirror.example.com/finx/seed
curl -fsSL https://raw.githubusercontent.com/Fincote/Finx/HEAD/finx-install/install.sh | sudo bash
```

### 清单走一个域名，大文件走对象存储

两份地址分开是因为 CDN 与对象存储常常不是一个地方，更新频率也不同。

```sh
export FINX_INDEX_DOMAIN=https://cdn.example.com/finx/manifest-dir
export FINX_SEED_DOMAIN=https://oss.example.com/finx/seeds
```

注意 `FINX_SEED_DOMAIN` 只在**清单里没有 `url` 行**时才用得上。清单里写了
`url`，就以清单为准 —— 那是发布方对这个种子实际存放位置的声明。

### 预编译 .deb 走自己的镜像

```sh
export FINX_DEB_DOMAIN=https://mirror.example.com/finx/debs
```

### 一个镜像站包办全部

镜像站按 MacWave 的布局分目录（`Finx/bottle`、`Finx/sourcecode` …）时，只填基址：

```sh
export FINX_MIRROR_DOMAIN=https://mirror.repohub.top/Finx
```

某个 kind 想单独指到别处，再设它自己的变量即可（单个变量优先）。注意 `sudo`
会清空环境，所以首次安装时要把变量交给**真正跑脚本的那个 `sudo`**，而不是
写在 `curl` 前面（那样只有 `curl` 拿到变量）：

```sh
curl -fsSL <install.sh 的地址> \
  | sudo FINX_MIRROR_DOMAIN=https://mirror.repohub.top/Finx bash
```

### 连不上，缩短等待

```sh
export FINX_CONNECT_TIMEOUT=8
```

只管「连上要等多久」，不给下载总时长设上限。给总时长设上限会把慢速网络的
用户直接挡在门外，而慢不等于坏。

### 走代理

```sh
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
export no_proxy=localhost,127.0.0.1
```

代理必须用 `export`：源码自举那一段是以 root 跑的，安装器会把这些变量
**显式传给 `sudo`**（`sudo` 默认会清空环境）。不转发的话，`curl` 通了，
真正的下载却卡住，报错还只会说「连不上」。

### 完全离线

```sh
./finx-install/install.sh --seed-dir=/path/to/unpacked-seed
```

`--seed-dir` 不联网，也不需要上面任何变量。

---

## 三点五、探不到清单时会发生什么

安装器先探一次清单地址，结果分三种，处理方式不同：

| 结果 | 含义 | 行为 |
| --- | --- | --- |
| 存在 | 有种子 | 走种子 |
| 服务端明确回 4xx/5xx | 还没发布 | 退回源码自举，并说明要编译 |
| 连不上 / 超时 / DNS 失败 | **网络问题** | **停下**，提示设代理或换镜像 |

第三种刻意不退回源码：源码自举要从 SourceForge 下载，而连不上 GitHub 的网络
通常也连不上 SourceForge，于是用户会先看到「要编译十几分钟」，再挂在下载上。
真要走那条路就显式加 `--from-source`。

探测本身会重试 3 次（每次间隔 2 秒）：实测过同一条命令前一分钟能取到清单、
下一分钟就 connect timeout，一次失败不足以判定「没有种子」。

## 三点六、种子与 macOS 版本

种子里每个 `.deb` 都带着 `darwin (>= N-1)` 依赖，`N` 是**构建机**的 Darwin 主版本。
所以种子只对「构建它那一代及更新」的 macOS 可用：

| 构建于 | 依赖 | 可用于 |
| --- | --- | --- |
| macOS 15（Darwin 24） | `darwin (>= 24-1)` | 15、26 及更新 |
| macOS 26（Darwin 25） | `darwin (>= 25-1)` | 仅 26 及更新 |

因此 CI 在 `macos-15` 上构建，**不能用 `macos-latest`** —— 在最新系统上构建，
产出的包会把老系统全部挡在门外，而失败点很靠后：种子能装、文件都在，直到
`finx install <任何包>` 才报

```
lzma depends on darwin (>= 25-1); however:
  Version of darwin on system is 24.5.0-1.
```

安装器现在会读清单里的 `darwin` 字段，在**解包之前**就拒绝不匹配的种子。

所以种子按 Darwin 主版本**各出一份**，标签形如 `seed-21`、`seed-24`：

| 种子 | 构建于 | 可用于 |
| --- | --- | --- |
| `seed-21` | macOS 12 Monterey | 12 及更新 |
| `seed-23` | macOS 14 Sonoma | 14 及更新 |
| `seed-24` | macOS 15 Sequoia | 15 及更新 |
| `seed-25` | macOS 26 Tahoe | 26 及更新 |

安装器按 `uname -r` 的第一段自动挑，用户不用配任何东西：

```
https://github.com/Fincote/Finx/releases/download/seed-<本机 Darwin>/manifest
```

清单里的 `darwin` 字段仍是最终判据：装到更老的系统上会在**解包之前**被拒绝，
哪怕标签贴错了。CI 也会比对 runner 的 `uname -r` 与请求的 `darwin`，贴错标签直接失败。

**要支持更老的系统，就得在更老的机器上构建。** GitHub 已移除 `macos-12` 及更早的
runner，所以 12 及以下只能自备机器跑 `scripts/ci_bootstrap.sh` 再手动上传。

### 本机没有对应版本的种子时，往下找

二进制记的是**构建时**的 Darwin：低处编的能在高处跑，反之不行。所以 macOS 14
（Darwin 23）上没有 `seed-23` 时，`seed-21` 完全可用 —— 安装器会逐个往下试：

```
Darwin 23 → seed-23（没有）→ seed-22（没有）→ seed-21（有）✓
```

三个终止条件：

| 探测结果 | 动作 |
| --- | --- |
| 有清单 | 用它 |
| 服务端明确回 404 | 试下一档 |
| 连不上／超时 | **停** —— 这不是「没有」而是「问不到」，再试只会让用户多等几轮超时 |

试到 `FINX_LOWEST_SEED_DARWIN`（默认 21）为止。

**显式指定来源时不做这个搜索**：给了 `--manifest-url` 或 `FINX_INDEX_DOMAIN` 就只试
那一个 —— 调用方说了用哪份，再换一个等于把他的指定丢掉。

这个机制让种子的覆盖面变成「**最低那一版决定一切**」：有了 `seed-21`，
Darwin 21 以上全都有种子可用，不必每个版本各编一份。

## 三点七、源码包镜像

**树里全部 30 个包里，29 个的上游源码 tar 都放在
[`Fincote/Finx-source`](https://github.com/Fincote/Finx-source) 的 `src-1` 发布里**，
平铺存放，共 25 个文件：

```
https://github.com/Fincote/Finx-source/releases/download/src-1/<上游原名>
```

第 30 个是 `base-files`：它的源码由本仓库的 `base-files/pack.sh` 就地生成，从不下载。

包描述通过 `CustomMirror` 指向它。GitHub 的发布资产没有目录结构，所以 `Source:` 里
原有的 `fink/` 路径前缀被去掉了 —— 否则会解析成 `.../src-1/fink/<文件名>`，404。

### 为什么这里不按包名分 Release

`Fincote/debs` 是一个包一个 Release（Bottle 形式），源码这边**不是**，理由是两者不同类：

| | 二进制 | 源码 |
| --- | --- | --- |
| 平台变体 | 有（arch + Darwin）→ 必须进文件名 | 无 → 不需要消歧 |
| 文件名唯一性 | 需要拼装 | 上游原名本来就全局唯一 |
| 共用 | 不存在 | **4 个 tar 被两个包共用** |

那 4 处共用：

```
dpkg_1.19.7.tar.gz          dpkg, dpkg-bootstrap
tar-1.29.tar.bz2            tar, tar-bootstrap
ncurses-5.9-20110507.tgz    ncurses, libncursesw5
gettext-0.22.5.tar.gz       gettext-tools, libgettext8-shlibs
```

按包名分 tag 会把同一份字节存两遍。所以源码侧是**一个只增不删的扁平 Release**
（要换代就 `src-2`），字节保持上游原样 —— 校验值因此等于上游公布的值。

重新生成这份镜像：

```sh
./scripts/fetch_sources.sh <目录>     # 树里每一个包，含 CPAN 与 SourceForge 那些
```

它会逐个核对 `Source-MD5` / `Source-Checksum`。镜像返回「200 + HTML 错误页」是
发生过的事，光看 curl 退出码不够。

`src-1` 还带 `SHA256SUMS`（25 个文件全在里面）与 `build.txt`（形态与由来）。

### 镜像组的顺序

Fink 有两套镜像来源：`master`（`distfiles.*.finkmirrors.net` 那一批）和包描述里
`CustomMirror` 定义的组。哪个先试由 `finx.conf` 的 `MirrorOrder` 决定。

我们一律写 `MasterLast`：包自己声明的来源优先，master 垫底。

不写会有问题，而且很隐蔽：`Fink::Configure::configure()` 的提问默认值是
`MasterFirst`（`Configure.pm:637`），而 `NetAccess.pm:188` 自己的默认是
`MasterLast`。bootstrap 以 `< /dev/null` 跑 configure 时会取前者的默认，于是
**每个包都先去试那批常年解析不了的 master 主机**，失败一次才跳到我们的镜像。
实测 22 个包，每个都白试一次。

**这一层解决什么、不解决什么**：CI 跑在 GitHub 的机器上，从这里取源码不再碰
SourceForge 那批常年死掉的镜像，构建时间与失败率都降下来。但**对网络受限的
本机不解决问题** —— GitHub 本身不可达时，任何 GitHub 托管的地址都不可达。
那种情况只能用种子（`--seed-dir`）或 U 盘预置源码，见
[`OFFLINE.md`](./OFFLINE.md)。

## 三点八、仓库里的 `mirror/` 是什么

`mirror/` 是 **bootstrap 期间的镜像数据**，不是包的源码。这一点容易看错，说清楚：

`bootstrap` 里有一行 `$Fink::Config::libpath = $homebase`（`bootstrap:769`）——
把 `libpath` 指到源码树根，于是 `Fink::Configure::configure()` 读的
`$libpath/mirror/_keys` 与 `_list` 就是**仓库里的这两份**。缺一个就直接
`die "File ... not found. Please install the fink-mirrors package"`。

而 `fink-mirrors` 这个包本身构建的是**上游 tar 包**
（`Fincote/Finx-source/src-1/fink-mirrors-0.43.0.1.tar.gz`，字节与上游一致），
它把数据装到 `lib/finx/mirror/`。所以：

| 位置 | 谁在用 | 改它有用吗 |
| --- | --- | --- |
| 仓库 `mirror/*`（除三个脚本） | bootstrap 的 configure、`Mirror.pm` 找 `mirror:<名字>:` | 有用，但只影响自举那一刻 |
| 仓库 `mirror/{inject.pl,install.sh,postinstall.pl.in}` | **没有人** —— 构建用的是 tar 包里那三份 | 没用。`fink-mirrors.info` 的 `CompileScript` 就地做 `lib/fink` → `lib/finx` 的改写 |
| 装好的 `$prefix/lib/finx/mirror/*` | `finx configure`、`Mirror.pm`、`SelfUpdate` | 有用，来源是 tar 包 |

三个脚本留在仓库里只是给人对照上游，它们已经有 `user warnings;` 这种拼写错误
（`inject.pl:29`，运行即 `warnings->user` 报错）而长期没人发现，正说明没人跑过。

### 每个文件的旧用途

删掉的四个 CVS/网站地址文件与一个 2003 年的待办：

| 文件 | 旧用途 | 为什么删 |
| --- | --- | --- |
| `TODO` | Fink 镜像管理者的待办（"contact Atlanta to write a LOCAL"） | 2003 年的；这些镜像站与 Finx 无关 |
| `cvs-repository` / `anonymous-cvs` / `developer-cvs` | `finx selfupdate-cvs` 的仓库地址 | Finx 不自举 CVS；`SelfUpdate::CVS` 里读这三个文件时都有 `-f` 守卫，缺了不影响 |
| `website` | `selfupdate-point` 拼下载地址时用的官网 | 现在 `SelfUpdate/point.pm` 只认 `FINX_SELFUPDATE_DOMAIN`，不再读这个文件 |
| `_urls` | 上面四个文件在 `lib/finx/URL/` 里的登记表 | 只登记了这四项，随它们一起删 |
| `apt` | Fink 二进制分发（`bindist.finkmirrors.net`）的 apt 仓库列表 | Finx 的二进制分发是 `Fincote/debs`；这个域名早已不服务。已同时从 `_list` 的 `Order:` 里摘掉 |

留下的都是**通用上游镜像列表**，随 `.info` 里的 `mirror:<名字>:` 被按需取用：

| 文件 | 对应 |
| --- | --- |
| `_list` | 列表注册表；`Order:` 一行决定 `finx configure` 会问哪几组 |
| `_keys` | configure 界面用的地区 / 国家键 |
| `master` | Fink master 镜像（`distfiles.*.finkmirrors.net`），`MirrorOrder` 决定先后 |
| `rsync` | `selfupdate-rsync` 的镜像 |
| `gnu` `gnome` `gimp` `kde` `apache` `debian` `freebsd` `ctan` `cpan` `sourceforge` | 各自上游项目的镜像 |

**当前树里没有任何包用到上表最后一行的名字** —— 30 个包全部走
`mirror:custom:`（指向 `Finx-source`），唯一一处 `mirror:gnu:` 是
`libiconv.info:16` 里被注释掉的那行。它们留着是为了以后收 GNU / CPAN 那类包时
不必重新造数据。

### 改 `mirror/` 时的硬约束

`_list` 的 `Order:` 与目录里的文件**必须一一对应**：`configure()` 对 `Order` 里的
每个名字都调 `read_properties_multival("$libpath/mirror/$name")`，而那个函数在
文件缺失时**直接 `die`**（`Services.pm:384`）。所以删一个列表文件，必须同时从
`Order:` 里摘掉它 —— 否则下一次 `bootstrap` 会死在镜像选择那一步。

`postgresql` 是个例外：它有标题行，但本来就**不在 `Order:` 里**（上游留下的
不一致），`configure` 从不问它。文件留着，`.info` 用 `mirror:postgresql:` 时仍可解析。

---

## 四、只有地址能被替换，校验不能

这一条是底线，写在这里反复强调：

- 换镜像**不改变** SHA256。种子仍然按清单里的 `sha256` 与 `size` 逐字节核对，
  任何一项不符就中止，不做「警告后继续」。
- 清单里 `arch` 与本机不符直接拒绝。
- 镜像的语义是「从哪儿拿」，不是「信不信」。

所以放心把地址指向任何你信任的传输通道 —— 它拿不到绕过校验的能力。

地址格式也有硬约束：

- 只接受 `https://` 与 `file://`
- 明文 `http://` 只放行 `127.0.0.1:端口` 与 `localhost:端口`（离线测试用）
- 末尾斜杠统一去掉，否则拼出双斜杠，有些服务端会因此回 404
- 报错里带变量名 —— 同时改了三个变量中的一个却填错时，光说 "invalid URL" 帮不上忙

---

## 五、自建镜像需要放什么

三样东西，形状都只是「域名之后的一段相对路径」，所以 `rsync` + `nginx` 就够，
镜像站不需要理解任何协议。

### 种子（可选）

```
<域名>/manifest        清单（纯文本）
<域名>/seed.tar.gz     种子（默认文件名，可改，但要与 manifest 里 seed 行一致）
```

清单是行取向的纯文本，故意不用 JSON —— 安装阶段不该依赖 `jq`：

```
schema 1
release 1.0.0-beta3
arch arm64
seed seed.tar.gz
size 21111384
sha256 <64 位十六进制>
url https://.../seed.tar.gz      ← 可选
```

字段全部由 `scripts/make_seed.sh` 生成，不要手写。

### 源码归档

```
<域名>/tar.gz/<ref>          ref 是分支、标签或提交，默认 main
```

### 预编译 .deb（Bottle 形式）

一个包一个 Release，同一个 tag 下不同平台并存：

```
<域名>/<包名>/<包名>@<版本>-<修订>.darwin<Darwin>-<架构>.deb
```

例如：

```
默认：https://github.com/Fincote/debs/releases/download/dpkg/dpkg@1.19.7-1.3.darwin24-arm64.deb
镜像：https://mirror.example.com/finx/debs/dpkg/dpkg@1.19.7-1.3.darwin24-arm64.deb
                                            └──────── 域名之后完全相同 ────────┘
```

**Darwin 主版本必须进文件名。** 同一个 `dpkg@1.19.7-1.3` 在 macOS 12 与 15 上编出来的
是两个文件：每个 `.deb` 都带 `darwin (>= N-1)` 依赖，装错了 dpkg 会拒绝。所以
`darwin21-x86_64` 与 `darwin24-arm64` 不能互相顶替。

**每个 Release 必须带一份 `SHA256SUMS`。** 格式就是 `sha256sum` 的输出：

```
b19b6392d6512e1661e0113b4d62134be56eb18788ed1a9a6e334e88a3a2edd6  dpkg@1.19.7-1.3.darwin24-arm64.deb
```

`finx install` 会先取它、再下载，对不上就删掉文件并中止 —— 不留一个坏 `.deb`
在缓存里等着被 `dpkg -i`。缺这一份文件，或里面没有本平台那一行，安装会直接失败
并提示「没有这个平台的预编译包」。

它挡的是传输损坏和「文件被换过」这类错配，**挡不住恶意镜像**：两份文件来自同一台
主机。真正的信任边界是那个域名本身，见下面第四节。

**只增不删。** 镜像侧同步请用「只补缺失」，不要 `--delete` —— 上游删掉一个资产，
等于让某个版本永久消失，而存档意义正是反过来的。

**镜像不需要做的事：**

- 不需要模拟容器 registry（没有按 digest 取字节的接口）
- 不需要提供 apt 的 `Packages` 索引 —— 这套 `.deb` 由 Finx 自己按名字取，不走 apt 的源列表
- 不需要 https 才能用：`finx_domain` 也接受 `file://`，本地目录与 U 盘都行
  （明文 `http://` 只给回环地址，见 `Fink::Domains` 的校验）

### 规划中的 `mirror.repohub.top`

自有服务器，目录结构与 MacWave 一致：**域名顶层留给别的产品**，每个产品一层，
各 `kind` 再各一层。Finx 未来占：

```
https://mirror.repohub.top/
├── MacWave/          （已有）
│   ├── bottle/
│   └── deps/
├── LinuxWave/        （可能）
└── Finx/             ← 这一层还没有
    ├── bottle/       ≈ FINX_DEB_DOMAIN
    ├── core/         ≈ FINX_SOURCE_DOMAIN
    ├── sourcecode/   ≈ FINX_SOURCECODE_DOMAIN
    ├── selfupdate/   ≈ FINX_SELFUPDATE_DOMAIN
    └── api/          ≈ FINX_API_DOMAIN
```

**开关已经就位，只差数据。** 因为每个 `kind` 的目录名与 `Fink::Domains` 的名字
一一对应，站点上线后用户只需要一行：

```bash
export FINX_MIRROR_DOMAIN=https://mirror.repohub.top/Finx
```

单点的变量（例如 `FINX_DEB_DOMAIN`）仍然优先，可以用来把某一块单独指到别处。

**为什么现在不填进默认值**：默认值必须是一个此刻真能下载的地址。等 `Finx/`
这一层有内容了，再把 `Domains.pm` 的 `%DEFAULTS` 逐个改过去 —— 改一个 kind 就
是改一行，不必动解析逻辑。

**取源码这一条已经通了**：`FINX_SOURCECODE_DOMAIN`（含基址派生）会替换 `.info`
里指向官方池的那串地址，所以镜像一旦有 `Finx/sourcecode/`，`finx install` 就
真的从那里取。`.deb` 那条通道还没接（见下节）。

---

## 六、这些变量**不**管什么

- **不管包仓库的目录结构。** 装软件包时用哪个 dists、哪些 trees，由 `finx.conf` 里的
  `Trees` 与 `Distribution` 决定，不是安装器的事。
- **`FINX_DEB_DOMAIN` 现在真的生效了，但只在这一条路径上。** `finx install`
  在 `UseBinaryDist` 打开时，自己按
  `<域名>/<包名>/<包名>@<版本>-<修订>.darwin<Darwin>-<架构>.deb` 下载，用同一个
  Release 下的 `SHA256SUMS` 校验，然后照旧 `dpkg -i` 本地文件 —— apt 不再参与
  下载（它 0.5.4 也没有 https method）。装进
  `<前缀>/var/cache/finx/bottles/`，与 apt 的 archives 分开。
  没有配地址时仍走老的 `apt-get --download-only`。
- **不管已安装的 Finx 自身更新。** `finx selfupdate` 走自己的仓库地址。
- **不是必需的。** 全部不设，`curl | bash` 就该能装成。

---

## 七、改这些变量时要跑什么

```sh
make test                          # 含 structure / sources_check
./finx-install/selftest.sh         # 域名校验、超时、sudo 代理转发、往下找种子
```

`finx-install/install.sh` 是唯一源文件，没有生成步骤 —— 改了推上去就生效。
`selftest.sh` 是它唯一的防线，尤其是那 166 处命令替换在 `set -eE` 下的行为。
