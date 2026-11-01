# finx-install

面向用户的 Finx 安装器。

**这不是 `fink` 包的安装阶段脚本。** 那个是仓库根的 [`install.sh`](../install.sh)，
由 [`fink.info.in`](../fink.info.in) 的 `InstallScript` 调用。两者的命名冲突与取舍见
[`docs/TECHNICAL-GUIDE.md`](../docs/TECHNICAL-GUIDE.md) 8.7。

## 一、一条命令

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fincote/Finx/HEAD/finx-install/standalone.sh)"
```

带参数时，`--` 之后的都传给安装器：

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fincote/Finx/HEAD/finx-install/standalone.sh)" -- --dry-run
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fincote/Finx/HEAD/finx-install/standalone.sh)" -- --prefix=/opt/finx
```

从仓库直接跑（开发、离线自测）：

```
./finx-install/install.sh --dry-run
```

## 二、目录结构

```
finx-install/
├── install.sh            模块化入口：解析参数、编排七个阶段
├── standalone.sh         生成物：自包含单文件，供 curl | bash 使用
├── build-bundle.sh       把 install.sh + lib/*.sh 打平成 standalone.sh
├── selftest.sh           沙箱自测：19 项断言，全程离线
├── lib/
│   ├── common.sh         输出、错误、trap、临时目录、sha256、测试根
│   ├── detect.sh         宿主探测（macOS 版本 / 架构）、目标目录状态、写权限
│   ├── manifest.sh       清单解析、多镜像下载与续传、体积与 sha256 校验
│   └── extract.sh        解包、权限归一、Mach-O ad-hoc 重签名、写配置、重建索引
└── seed/
    └── manifest.example  清单格式参考
```

## 三、`standalone.sh` 是生成物

`install.sh` + `lib/*.sh` 是**唯一事实来源**，`standalone.sh` 由
[`build-bundle.sh`](./build-bundle.sh) 打平生成：

```
./finx-install/build-bundle.sh           # 重新生成
./finx-install/build-bundle.sh --check   # 只校验是否同步（CI 用）
```

为什么产物要提交进仓库：`/bin/bash -c "$(curl -fsSL ...)"` 只拿得到一个文件，
被管道执行时既没有可靠的 `$0`，也没有同级目录可以 `source`。

改完 `lib/` 里的任何文件后必须重新生成，否则线上那条命令跑的还是旧逻辑。
`--check` 就是防这个漂移的。

## 四、七个阶段

```
1. 体检      macOS 版本、架构、目标目录状态、写权限
2. 解析清单  本地目录（--seed-dir）或远端 URL（--manifest-url）
3. 取产物    本地拷贝，或按清单里的 url 逐个尝试（.part 续传）
4. 校验      体积 + SHA256，任一不符即中止
5. 落盘      mkdir 前缀 → tar 解到前缀
6. 收尾      权限归一、Mach-O ad-hoc 重签名、写 fink.conf
7. 收束      fink scanpackages，提示 source <prefix>/bin/init.sh
```

**校验在落盘之前**：失败时不会留下一个空壳目录。

## 五、设计取舍

| 取舍 | 理由 |
| --- | --- |
| 清单用行取向纯文本，不用 JSON | 安装阶段不该依赖 `jq`；`awk` 一行取字段，diff 与签名都更友好 |
| 先校验再 `mkdir` / 解包 | 失败不留残骸，重跑不需要先手工清理 |
| 只有**一条**网络路径（清单里的 url） | 拒绝在安装期间引入第二个不可校验的下载源 |
| `standalone.sh` 提交进仓库 | 见第三节；用 `--check` 防漂移 |
| `--seed-dir` 一等公民 | 让整个安装器可以完全离线自测，CI 不需要网络 |
| 不做「警告后继续」 | 校验失败即中止，与 `docs/TECHNICAL-GUIDE.md` 8.1 的强校验要求一致 |
| 前缀归 root，不 chown 给调用者 | 见 TECHNICAL-GUIDE 8.6：chown 既免不了 `fink install` 的密码，又会让 `$prefix/bin/dpkg` 变成 root 的可控输入。这里采纳 MacPorts 模型 —— 每次装包都要 sudo，但只需要一份系统级二进制分发 |

## 六、测试根：`FINX_TEST`

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

## 七、自测

一条命令跑完 19 项断言，全程离线、不碰真实目录：

```
./finx-install/selftest.sh
```

自建临时测试根并在结束时删除。想保留结果就自己给一个：

```
FINX_TEST=/tmp/finx-check ./finx-install/selftest.sh
```

覆盖的场景：dry-run 不留痕、默认前缀落在测试根内、种子解包正确、`fink.conf` 记录沙箱前缀、
重复安装被拒、越界前缀被拒（含 `..` 与符号链接两种逃逸）、sha256 不符被拒且不留目录、
管道模式可装、`standalone.sh` 与源同步、多镜像回退、清单不可达被拒。

假种子里刻意放了两样容易被忽略的东西：

- **一个真的 Mach-O**（用 `cc` 现场编）。否则 `resign_macho` 只会打印 `re-signed 0`，
  签名分支等于从没执行过。断言要求它确实被重签，且 `codesign -v` 通过。
  机器上没有 `cc` 时明说跳过，不假装通过。
- **`init.sh`**。安装器的收尾提示会让用户 `source` 它，假种子缺了这条提示就是空话。

下载路径也真的走了一遍：多镜像那组用 `file://` URL 模拟，第一个地址指向不存在的文件，
断言安装仍然成功、且日志里报告了那次镜像失败。

手工验证时也建议走同一个根：

```
BASE=$(mktemp -d)
mkdir -p "$BASE/seed/bin" "$BASE/seed/lib/fink" "$BASE/seed/etc"
printf '#!/bin/sh\necho "stub fink $*"\n' > "$BASE/seed/bin/fink"
chmod 755 "$BASE/seed/bin/fink"
tar -czf "$BASE/seed.tar.gz" -C "$BASE/seed" .

SIZE=$(wc -c < "$BASE/seed.tar.gz" | tr -d ' ')
SHA=$(shasum -a 256 "$BASE/seed.tar.gz" | awk '{print $1}')
printf 'schema 1\nrelease 0.46.0\narch %s\nseed seed.tar.gz\nsize %s\nsha256 %s\n' \
    "$(uname -m)" "$SIZE" "$SHA" > "$BASE/manifest"

FINX_TEST="$BASE" ./finx-install/install.sh --seed-dir="$BASE" --dry-run
FINX_TEST="$BASE" ./finx-install/install.sh --seed-dir="$BASE"
cat "$BASE/opt/finx/etc/fink.conf"

# 管道模式
cat finx-install/standalone.sh | FINX_TEST="$BASE" /bin/bash -s -- --seed-dir="$BASE" --prefix="$BASE/piped"
```
