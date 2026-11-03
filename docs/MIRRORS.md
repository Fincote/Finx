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
| `FINX_SOURCE_REF` | `main` | 源码的分支/标签/提交，等同 `--ref` |
| `FINX_CONNECT_TIMEOUT` | `30` | 连不上的等待秒数。**只管连接**，不管下完要多久 |
| `FINX_DEFAULT_MANIFEST_URL` | 见下面的优先级 | 直接给出清单的完整 URL，绕过上面的拼装 |
| `FINX_MANIFEST_URL` | 空 | 等同 `--manifest-url`：显式指定清单，且**不回落**源码 |

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

## 三点七、源码包镜像

bootstrap 需要的 22 个上游源码 tar 放在
[`Fincote/Finx-source`](https://github.com/Fincote/Finx-source) 的 `src-1` 发布里，
平铺存放：

```
https://github.com/Fincote/Finx-source/releases/download/src-1/<文件名>
```

包描述通过 `CustomMirror` 指向它。GitHub 的发布资产没有目录结构，所以那 20 个包的
`Source:` 里原有的 `fink/` 路径前缀被去掉了 —— 否则会解析成
`.../src-1/fink/<文件名>`，404。

`base-files` 是唯一例外：它的源码由本仓库的 `base-files/pack.sh` 就地生成，
从不下载，所以保持原样。

重新生成这份镜像：

```sh
./scripts/fetch_sources.sh <目录>     # 只下 CustomMirror 指向我们的那些包
```

它会逐个核对 `Source-MD5` / `Source-Checksum`。镜像返回「200 + HTML 错误页」是
发生过的事，光看 curl 退出码不够。

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

一个可用的镜像目录只有两个文件：

```
<域名>/manifest        清单（纯文本）
<域名>/seed.tar.gz     种子（默认文件名，可改，但要与 manifest 里 seed 行一致）
```

清单是行取向的纯文本，故意不用 JSON —— 安装阶段不该依赖 `jq`：

```
schema 1
release 0.1.0-alpha.git
arch arm64
seed seed.tar.gz
size 21111384
sha256 <64 位十六进制>
url https://.../seed.tar.gz      ← 可选
```

字段全部由 `scripts/make_seed.sh` 生成，不要手写。

---

## 六、这些变量**不**管什么

- **不管包仓库。** 装软件包时用哪个 dists、走哪个二进制源，由 `finx.conf` 里的
  `Trees` 与 `Distribution` 决定，不是安装器的事。
- **不管已安装的 Finx 自身更新。** `finx selfupdate` 走自己的仓库地址。
- **不是必需的。** 全部不设，`curl | bash` 就该能装成。

---

## 七、改这些变量时要跑什么

```sh
make test                          # 含 structure / sources_check
./finx-install/selftest.sh          # 域名校验、超时、sudo 代理转发的断言
./finx-install/build-bundle.sh      # 改了 lib/ 必须重建 install.sh
./finx-install/build-bundle.sh --check   # 只校验产物与源同步
```

改了 `finx-install/lib/` 里的东西却忘了重建 `install.sh`，用户拿到的还是旧的
单文件 —— `--check` 与 CI 都会拦住这件事。
