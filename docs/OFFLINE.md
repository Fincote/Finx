# 离线安装

什么时候需要这份文档：目标机器**连不上 GitHub**，或者连得上但慢到不可用。

分三种情况，按代价从低到高：

| 情况 | 做法 | 需要网络 |
| --- | --- | --- |
| 有网但不稳 | 走代理，见第一节 | 是 |
| GitHub 不可达，但有另一台能上网的机器 | U 盘带种子过去，见第二节 | 传输时可离线 |
| 想彻底离线自举（老系统，没有对应种子） | U 盘带源码包，见第三节 | 只在准备阶段 |

---

## 一、有网但不稳

先分清**哪一段**要走代理。安装器的下载分两类地址：

| 用途 | 域名 |
| --- | --- |
| 取安装脚本本身 | `raw.githubusercontent.com` |
| 取种子清单与种子 | `github.com`、`objects.githubusercontent.com` |
| 自举时取源码 | `github.com`（`Finx-source` 的发布资产） |

只给 `github.com` 配代理**不够** —— `raw.githubusercontent.com` 与
`objects.githubusercontent.com` 是两个不同的主机。这三个都要覆盖：

```sh
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
export no_proxy=localhost,127.0.0.1

curl -fsSL https://raw.githubusercontent.com/Fincote/Finx/HEAD/finx-install/install.sh | sudo bash
```

安装器会把代理变量**显式传给 `sudo`**（`sudo` 默认清空环境），所以自举那一段的
下载也能走代理。

**验证代理是否覆盖到位**，逐条试：

```sh
for u in \
  https://raw.githubusercontent.com/Fincote/Finx/HEAD/VERSION \
  https://github.com/Fincote/Finx/releases/download/seed-24/manifest ; do
    printf '%-80s ' "$u"
    curl -sS -o /dev/null -w '%{http_code}\n' -m 20 "$u" || echo FAIL
done
```

`seed-24` 换成 `uname -r | cut -d. -f1` 的结果，或用 `seed` 试。

---

## 二、GitHub 不可达：U 盘带种子

种子是「装好的前缀的快照」，安装时只需解包、归一权限、重签 Mach-O、写配置、
重建索引 —— **全程不联网**。

### 在有网的机器上

从 Release 下载对应本机 Darwin 大版本的两个文件：

```
manifest
seed.tar.gz
```

放到同一个目录，例如 `finx-seed/`。`manifest` 里的 `darwin` 字段要与目标机器
的 `uname -r` 第一段一致（macOS 15 → 24，macOS 12 → 21）。见
[`MIRRORS.md`](./MIRRORS.md) 三点六。

### 在目标机器上

```sh
sudo bash /path/to/install.sh --seed-dir=/path/to/finx-seed
```

`install.sh` 本身可以从仓库拷过来（`finx-install/install.sh` 是自包含单文件）。
`--seed-dir` 会就地读 `manifest` 与 `seed.tar.gz`，不做任何网络请求。

安装器在解包**之前**会检查归档里有没有 `bin/finx`、`bin/dpkg`、`bin/dpkg-deb`，
缺任何一个直接拒绝 —— 免得装出一个空壳。

---

## 三、彻底离线自举

适用：目标机器的 macOS 太老，官方没有对应 Darwin 的种子（例如 Monterey，Darwin 21），
只能用那台机器自己编一次。

### 准备（在有网的机器上）

```sh
./scripts/fetch_sources.sh /path/to/usb/finx-src
```

它会把 bootstrap 需要的全部上游源码 tar 下到该目录，逐个核对
`Source-MD5` / `Source-Checksum`，并生成 `SHA256SUMS`。约 90 MB。

同时把源码树打成 tar：

```sh
git archive --format=tar.gz --prefix=Finx-main/ -o /path/to/usb/Finx-main.tar.gz HEAD
```

### 目标机器

```sh
# 1. 编译工具（这一步仍需网络，见下方注意）
xcode-select --install
sudo xcodebuild -license accept

# 2. 解源码树
cd ~ && tar -xzf /path/to/usb/Finx-main.tar.gz && cd Finx-main

# 3. 预置源码包
sudo mkdir -p /opt/finx/src
sudo cp /path/to/usb/finx-src/*.tar.* /path/to/usb/finx-src/*.tgz /opt/finx/src/
ls /opt/finx/src | wc -l          # 应是 22

# 4. 自举（此时完全不联网）
time sudo ./bootstrap /opt/finx < /dev/null
```

**为什么第 3 步就够了**：Fink 的 `find_tarball`（`PkgVersion.pm:2466`）第一个搜索
目录就是 `$basepath/src`。文件在那儿，它就不发起任何下载。

**判断有没有生效**：PHASE ONE 应该**几乎瞬间**完成。若它开始长时间下载，说明有
文件没放对位置 —— 立刻 `Ctrl-C`，别等三十分钟。

### 完成之后

```sh
ls /opt/finx/bin/{finx,dpkg,dpkg-deb,tar}
/opt/finx/bin/finx --version
```

四个文件必须都在。缺任何一个说明第三阶段没走完，往上翻日志找第一条
`dpkg: error processing package`。

打成该机器自己的种子，以后重装就不用再编：

```sh
D=$(uname -r | cut -d. -f1)
sudo ./scripts/make_seed.sh --prefix /opt/finx --out seed \
    --release 1.0.0-beta4 \
    --url "https://github.com/Fincote/Finx/releases/download/seed-$D/seed.tar.gz"
```

上传为 Release，标签 `seed-$D`，标题 `Seed-<release>-darwin$D-<arch>`。

`--url` 不能省。省了清单里就没有下载地址，安装器会回落到
`$FINX_SEED_DOMAIN/seed.tar.gz`（默认 `https://finx.sh/finx/seed/`）—— 那是给
自建镜像用的位置。放进 GitHub Release 时它指向错的地方，而失效方式很安静：
**清单探得到，种子下不来**。`make_seed.sh` 在缺 `--url` 时会打印这条提醒。

---

## 四、注意

**`xcode-select --install` 需要网络。** 它要下几百 MB 的命令行工具。如果那台机器
连这个都下不了，需要先把 CLT 装好（Apple 提供离线包，但走的是另一套流程，不在
本仓库范围内）。

**MacPorts 不冲突。** 它装 `/opt/local`，Finx 装 `/opt/finx`。装完后 `finx` 的
`init.sh` 会把自己加到 `PATH` 前面，两者互不遮蔽。

**离线装完之后，装新包仍可能要联网。** 种子自带 48 个 `.deb`（27 个包描述可用），
池里已有的包可以直接装；池里没有的要取源码，那需要能访问
[`Fincote/Finx-source`](https://github.com/Fincote/Finx-source)。想彻底离线装新包，
把需要的那几个源码 tar 也放进 `/opt/finx/src` 即可 —— 机制与第 3 步相同。
