# finx-install

面向用户的 Finx 安装器。

**这不是 `finx` 包的安装阶段脚本。** 那个是仓库根的 [`install.sh`](../install.sh)，
由 [`finx.info.in`](../finx.info.in) 的 `InstallScript` 调用。两者的命名冲突与取舍见
[`docs/TECHNICAL-GUIDE.md`](../docs/TECHNICAL-GUIDE.md) 8.7。

## 一、一条命令

```
curl -fsSL https://raw.githubusercontent.com/Fincote/Finx/HEAD/finx-install/install.sh | sudo bash
```

`sudo` 是必需的：默认前缀 `/opt/finx` 只有 root 能写。前缀本来就归你、不需要提权时
（`--prefix` 指向自己的目录），换成不带的写法：

```
/bin/bash -c "$(curl -fsSL .../finx-install/install.sh)" -- --prefix="$HOME/finx"
```

两种都**不要**写成 `sudo curl ... | bash` —— 那样只有 curl 是 root，bash 不是。

带参数时，`--` 之后的都传给安装器：

```
curl -fsSL .../finx-install/install.sh | sudo bash -s -- --no-path
curl -fsSL .../finx-install/install.sh | sudo bash -s -- --prefix=/opt/finx
```

`install.sh` 就是**可以直接下载的那一个文件** —— 没有 npm 式的安装步骤，也不
依赖同级的 `lib/`。管道里同时是它自己的 stdin，所以它不会反过来读 stdin 提问。

调试时想让步骤与错误说中文，加 `--zh`（或 `FINX_LANG=zh`）。只覆盖安装器自己
的话：`curl` 的进度条、编译器输出、bootstrap 日志一律保持原样 —— 那些不是我们的
话，翻译了反而更难搜。

未设任何环境变量时，它去 GitHub Releases 的 `seed` 标签取预编译种子；只有取不到
才会退回源码自举，而那条路会把 bootstrap 的全部输出（几百行）收进日志，屏幕上
只留进度与失败时的末尾 40 行。要看全程加 `--verbose`。

从仓库直接跑（开发、离线自测）：

```
./finx-install/install.sh        # 真装到 /opt/finx
./finx-install/selftest.sh       # 离线自测，不碰 /opt/finx
```

### 它怎么决定装法

```
给了 --seed-dir / --manifest-url   → 种子（严格，不换源）
否则先探默认种子清单
    探到                          → 种子
    探不到                        → 源码自举，并说明原因
给了 --from-source                → 直接源码自举
给了 --no-fallback                → 探不到种子就失败
```

**两条路的差别：**

| | 种子 | 源码自举 |
| --- | --- | --- |
| 耗时 | 几十秒 | 十几分钟起，视机器而定 |
| 需要 Xcode CLT | 否 | **是**（要现编 `tar` 与 `dpkg`） |
| 需要 root | 写入 `/opt/finx` 时 | 是 |
| 现在的状态 | **还没有种子** | 可用 |

也就是说：**今天跑那条命令，走的是源码自举**。第一条 `warn` 会明确说明这一点，不会让人以为在装预编译包。

### 源码模式为什么不用改 Fink

`bootstrap` 的所有提问都走 `Fink::CLI::get_input`，读到 EOF 返回空串，而每个提问都把空串当成「取默认值」。所以把 stdin 接到 `/dev/null` 就是全程回车 —— 不需要给 bootstrap 加 `--ci`，也不需要维护第二套交互逻辑。

提权由安装器先做（`sudo -v`），这样 `bootstrap` 一进来就是 root，不会走到它自己那个「Choose a method」提问。

## 二、目录结构

```
finx-install/
├── install.sh            唯一源文件，用户下载的就是它
├── selftest.sh           沙箱自测：全程离线，不碰真实目录
└── seed/
    └── manifest.example  清单格式参考
```

`install.sh` 内部按职责分段，段名就是注释里的分隔线，顺序也是执行顺序：

| 段 | 内容 |
| --- | ---- |
| 输出与错误 | `say` / `info` / `warn` / `die`、`t` 双语、`redact_url`、trap、临时目录、sha256 |
| 宿主探测 | macOS 版本 / 架构、目标目录状态、写权限 |
| 清单 | 解析、多镜像下载与续传、体积与 sha256 校验 |
| 解包 | 解包、权限归一、Mach-O ad-hoc 重签名、写配置、重建索引 |
| 链接 | 载荷符号链接的落点校验（豁免表与 `perlmod/Fink/Links.pm` 必须一致） |
| 源码回落 | 取源码树、检查前置条件、跑 bootstrap |

## 三、只有一个文件

`/bin/bash -c "$(curl -fsSL ...)"` 只拿得到一个文件，被管道执行时既没有可靠的
`$0`，也没有同级目录可以 `source` —— 安装器不能拆成多个 `.sh`。

这里曾经有过相反的做法：`install.sh.in` 模板 + `lib/*.sh`，由 `build-bundle.sh`
拼成 `install.sh`，CI 用 `--check` 防漂移。已经拆掉。2000 行在一个文件里是可以
维护的，而那套机制的真实代价不是几个脚本，是**改了产物会被下次构建静默覆盖**——
手改和脚本输出指向同一个文件，出错时不提示。现在只有一处可改，那个失败模式不存在。

单文件下有两个自己造的坑要提防：一是 `set -eE` 与「返回非零是正常信号」的函数
之间的冲突（`probe_url` 因此改用 `PROBE_RESULT` 传结果、不传退出码），二是有
166 处命令替换，任何一处的失败都会终止整个安装。`selftest.sh` 是这两条的唯一防线。

## 四、阶段

```
1. 体检      macOS 版本、架构、目标目录状态、写权限
2. 选装法    探种子，或按参数决定（见第一节）
```

**种子模式**

```
3. 解析清单  本地目录（--seed-dir）或远端 URL（--manifest-url）
4. 取产物    本地拷贝，或按清单里的 url 逐个尝试（.part 续传）
5. 校验      体积 + SHA256，任一不符即中止
6. 落盘      mkdir 前缀 → tar 解到前缀
7. 收尾      权限归一、Mach-O ad-hoc 重签名、写 finx.conf
8. 收束      finx scanpackages，提示 source <prefix>/bin/init.sh
```

**校验在落盘之前**：失败时不会留下一个空壳目录。

**源码模式**

```
3. 取源码树  codeload 的 tar.gz，解包，确认含 bootstrap 与 VERSION
4. 查前置    cc、pod2man、perl —— 先查再跑，免得半小时后才失败
5. 自举      sudo ./bootstrap <prefix> < /dev/null
```

bootstrap 自己会建前缀、写配置、建索引，所以源码模式没有收尾阶段。

## 五、设计取舍

| 取舍 | 理由 |
| --- | --- |
| 清单用行取向纯文本，不用 JSON | 安装阶段不该依赖 `jq`；`awk` 一行取字段，diff 与签名都更友好 |
| 先校验再 `mkdir` / 解包 | 失败不留残骸，重跑不需要先手工清理 |
| 只有**一条**网络路径（清单里的 url） | 拒绝在安装期间引入第二个不可校验的下载源 |
| `install.sh` 提交进仓库 | 见第三节；用 `--check` 防漂移 |
| `--seed-dir` 一等公民 | 让整个安装器可以完全离线自测，CI 不需要网络 |
| 不做「警告后继续」 | 校验失败即中止，与 `docs/TECHNICAL-GUIDE.md` 8.1 的强校验要求一致 |
| 前缀归 root，不 chown 给调用者 | 见 TECHNICAL-GUIDE 8.6：chown 既免不了 `finx install` 的密码，又会让 `$prefix/bin/dpkg` 变成 root 的可控输入。这里采纳 MacPorts 模型 —— 每次装包都要 sudo，但只需要一份系统级二进制分发 |

## 六、还没做的（按优先级）

| 待办 | 为什么 | 影响 |
| --- | --- | --- |
| **产出并发布种子** | 有了它，那条命令才真正是几十秒装完 | 一条命令的体验从「十几分钟」变成「几十秒」 |
| **`--ci`** | 参照 MacWave `install.sh` 的 `--ci`：绝不等待输入，提权只接受已是 root 或免密 sudo，否则直接失败 | 没有它，CI 里提权会卡在密码提示上 |
| `--dir-option=N` | MacWave 用它免菜单选目录 | Finx 目前只有单一规范前缀，暂时用不上 |
| 种子清单签名 | 现在只有 SHA256，清单本身如何被信任还没解 | 决定校验链的顶端 |
| **下载源环境变量** | 仿照 MacWave 的 `MACWAVE_*_DOMAIN`：通过环境变量整体替换地址，不设则回落官方 | 决定国内可用性；命名与语义见下 |

`--ci` 的实现要点（写在这里，免得以后重新想）：在 `run_bootstrap` 决定提权方式时判断，
`CI_MODE=1` 时用 `sudo -n true` 探免密，探不到就带解释退出；非 CI 时照旧 `sudo -v`。

### 下载源环境变量：命名与语义

MacWave 的做法是**一个镜像主机下切若干路径**，一个账号覆盖全部：

```
MACWAVE_API_DOMAIN       包索引        infosource
MACWAVE_SELFUPDATE_DOMAIN 自更新数据    selfupdate
MACWAVE_PYTHON_DOMAIN    自带解释器     python
MACWAVE_CORE_DOMAIN      MacWave 自身   core
```

Finx 照搬这套形状，但只暴露**已经真的有消费方**的变量。MacWave 的
`MACWAVE_FILE_TIMEOUT`/`MACWAVE_SILENT`/`MACWAVE_BRANCH` 在那里是
`export` 给下一阶段脚本的，`install.sh` 自己并不读；原样搬过来只会在
Finx 里变成没人读的死配置，所以没有搬。

| 变量 | 默认值 | 覆盖什么 |
| --- | --- | --- |
| `FINX_INDEX_DOMAIN` | 不设则用 GitHub Releases 的 `seed` 标签 | 种子清单 `<域名>/manifest` |
| `FINX_SEED_DOMAIN` | `https://finx.sh/finx/seed` | 清单里没写 `url` 时的种子归档 `<域名>/<文件名>` |
| `FINX_SOURCE_DOMAIN` | `https://codeload.github.com/Fincote/Finx` | 源码归档 `<域名>/tar.gz/<ref>` |
| `FINX_SOURCE_REF` | `main` | 分支/标签/提交，等同 `--ref` |
| `FINX_CONNECT_TIMEOUT` | `30` | 连不上的等待秒数；只管连接，不管下完 |

清单与归档各一个变量，是因为 CDN 与对象存储常常分开部署；但默认同源，
不设也能走通。

四条约束，写在这里是为了以后不要走偏：

1. **只有地址可以被替换，校验不能被跳过。** 换镜像不改变 SHA256，改了就必须失败。
2. **部分设置必须可用。** 任何一个变量没设，就回落官方地址，不能要求用户配齐。
3. **不设即官方。** 变量存在的意义是加速，不是必需；默认路径必须始终能走通。
4. **地址只接受 `https://` 与 `file://`**，外加 `http://127.0.0.1:端口` 与
   `http://localhost:端口`（离线测试用）。末尾斜杠统一去掉，否则拼出双斜杠，
   有些服务端会因此回 404。报错里带变量名——改了三个变量中的一个却填错时，
   光说 "invalid URL" 帮不上忙。

`install.sh` 自身**没有**自举或自更新逻辑，也不需要域名变量：镜像带完整目录
结构，用户直接从镜像取 `install.sh` 即可。

实现上有一个坑值得记住：`finx_domain` 校验失败时 `exit 1`，但那行跑在
`$( )` 子 shell 里，只结束子 shell 而不管父进程。所以每个赋值后面必须跟
`|| exit 1`——否则填错一个域名得到的不是报错，而是一个变量被清空、
悄悄失效的安装器。

## 七、测试根：`FINX_TEST`

`FINX_TEST=<绝对路径>` 把整次运行关进这个目录，作用等同于 MacWave 的 `MACWAVE_TEST`：

| 项 | 行为 |
| --- | --- |
| 默认前缀 | 变成 `<测试根>/opt/finx` |
| 临时文件 | `TMPDIR` 改到 `<测试根>/tmp`，`mktemp` 无处可逃 |
| `--prefix` | 只允许指向测试根内部，越界即中止 |
| 拒绝的取值 | 相对路径、`/`、解析后落在 `/System`、`/usr`、`/Library`、`/Applications`、`/bin`、`/sbin` 的路径 |

```
FINX_TEST=/tmp/finx-check ./finx-install/install.sh --seed-dir=/tmp/seed
```

```
==> test root: /private/tmp/finx-check (nothing outside it will be touched)
    macOS 15, arch arm64, prefix /private/tmp/finx-check/opt/finx
```

两个细节：

- **先规范化再比对。** macOS 上 `/tmp` 是 `/private/tmp` 的符号链接，直接字符串比较会假阴性。
  `resolve_path` 会把路径最近的已存在祖先 `pwd -P` 之后再拼回剩余部分，所以
  `--prefix=<根>/link-out/...`（`link-out` 指向根外）同样会被拦住。
- **失败即中止，不降级。** 测试根写错时不会"当作没设置"继续跑真实目录 —— 那是唯一可能
  误伤真实安装的路径。

## 八、自测

一条命令跑完全套断言，全程离线、不碰真实目录：

```
./finx-install/selftest.sh
```

自建临时测试根并在结束时删除。想保留结果就自己给一个：

```
FINX_TEST=/tmp/finx-check ./finx-install/selftest.sh
```

覆盖的场景：`--help` 不留痕、默认前缀落在测试根内、种子解包正确、`finx.conf` 记录沙箱前缀、
重复安装被拒、越界前缀被拒（含 `..` 与符号链接两种逃逸）、sha256 不符被拒且不留目录、
管道模式可装、`install.sh` 与源同步、多镜像回退、清单不可达被拒。

假种子里刻意放了两样容易被忽略的东西：

- **一个真的 Mach-O**（用 `cc` 现场编）。否则 `resign_macho` 只会打印 `re-signed 0`，
  签名分支等于从没执行过。断言要求它确实被重签，且 `codesign -v` 通过。
  机器上没有 `cc` 时明说跳过，不假装通过。
- **`init.sh` 与 `pathsetup.sh`**。收尾提示会让用户 `source` 前者，并指向后者
  做持久化；假种子缺了它们，那条提示就是空话。

收尾**会**把 `init.sh` 那一行写进用户的 shell 启动文件 —— 否则 `curl | bash`
装完之后 `finx` 根本不在 PATH 上，等于断在最后一步。

三个安全约束：

- **按 `$SHELL` 选文件**：zsh → `.zprofile`、bash → `.bash_profile`（存在才是它，
  否则 `.profile`）、csh/tcsh → `.cshrc`。
- **以 root 跑时写调用者的家目录**：`curl | sudo bash` 下 `$HOME` 是 `/var/root`，
  所以用 `$SUDO_USER` + `dscl` 解析真实家目录，写完把属主改回去。
- **幂等**：那一行已存在就不重复追加。写失败则退回打印精确指令。

`--no-path` 关掉这一步。`FINX_TEST` 沙箱下**强制**关闭 —— 否则跑一次自测就会改掉
开发者本人的 `.zprofile`；写 PATH 那条逻辑由 `selftest.sh` 用假 HOME 单独测。

下载路径也真的走了一遍：多镜像那组用 `file://` URL 模拟，第一个地址指向不存在的文件，
断言安装仍然成功、且日志里报告了那次镜像失败。

手工验证时也建议走同一个根：

```
BASE=$(mktemp -d)
mkdir -p "$BASE/seed/bin" "$BASE/seed/lib/finx" "$BASE/seed/etc"
printf '#!/bin/sh\necho "stub finx $*"\n' > "$BASE/seed/bin/finx"
chmod 755 "$BASE/seed/bin/finx"
tar -czf "$BASE/seed.tar.gz" -C "$BASE/seed" .

SIZE=$(wc -c < "$BASE/seed.tar.gz" | tr -d ' ')
SHA=$(shasum -a 256 "$BASE/seed.tar.gz" | awk '{print $1}')
printf 'schema 1\nrelease 0.46.0\narch %s\nseed seed.tar.gz\nsize %s\nsha256 %s\n' \
    "$(uname -m)" "$SIZE" "$SHA" > "$BASE/manifest"

FINX_TEST="$BASE" ./finx-install/install.sh --seed-dir="$BASE"
cat "$BASE/opt/finx/etc/finx.conf"

# 管道模式
cat finx-install/install.sh | FINX_TEST="$BASE" /bin/bash -s -- --seed-dir="$BASE" --prefix="$BASE/piped"
```
