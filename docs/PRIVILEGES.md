# 哪些命令需要 root

Finx 把包装进 `/opt/finx`，那个前缀归 `root:wheel`，所以凡是改动前缀的命令都要
root。本文把命令表里的判据、实测结果、以及统计时撞见并已修掉的两个缺陷写清楚。

**你不必自己加 `sudo`。** 需要 root 的命令会通过 `RootMethod` 自己提权
（默认 `sudo`），所以你敲的是 `finx install tree`，密码由 finx 来问。

---

## 一、判据在哪

`perlmod/Fink/Engine.pm` 的 `%commands`，每条是四个字段：

```perl
'install' => [\&cmd_install, 1, 1, 2],
#             实现           ①  ②  ③
```

| 字段 | 含义 |
| --- | --- |
| ① | 是否要先读包描述 |
| ② | **是否需要 root**（本文讲的就是它） |
| ③ | 是否会调用 apt-get（0 不调、1 调、2 用 `--ignore-breakage` 调） |

共 45 条命令（含别名）：**15 条不需要 root，30 条需要**。

---

## 二、不需要 root 的 15 条（已实测）

全部在普通用户下跑过，`exit 0`：

| 命令 | 作用 |
| --- | --- |
| `list` | 列可用/已装包，可带过滤词 |
| `listpackages` | 同上，另一种输出 |
| `apropos` | 按关键词搜包 |
| `describe` / `desc` / `description` / `info` | 看某包的详情（四个名字同一实现） |
| `show-deps` | 看依赖（分「已装」与「编译」两侧） |
| `showparent` | 看某个 splitoff 属于哪个父包 |
| `splitoffs` / `splits` | 列某包的 splitoff |
| `dumpinfo` | 机器可读的包详情 |
| `validate` / `check` | 校验一个 `.info` 文件 |
| `plugins` | 列通知/校验和/自更新插件 —— **见第四节，它其实会失败** |

实测样例：

```
$ finx list tree
   	tree	2.3.2-1	Recursive directory listing program

$ finx show-deps tree
Package: tree (2.3.2-1)
To install the compiled package...
  The following other packages (and their dependencies) must be installed:
    [none]
```

写包侧也验过：树里 30 个 `.info` 全部通过 `finx validate`：

```
通过 30 / 失败 0
```

---

## 三、需要 root 的 30 条

按实现分组（同组是同一条命令的别名）：

| 组 | 命令 | 为什么要 root |
| --- | --- | --- |
| 装 | `install` `update` `enable` `activate` `use` | 解包、`dpkg -i`、写 dpkg 数据库 |
| 卸 | `remove` `delete` `disable` `deactivate` `unuse` `purge` | 删文件、改 dpkg 数据库 |
| 重建 | `reinstall` `rebuild` | 同上 |
| 取 | `fetch` `fetch-all` `fetch-missing` | 写 `$prefix/src`、`var/cache/apt` |
| 索引 | `scanpackages` `index` | 写 `$prefix/finx/**/Packages.gz` |
| 自更新 | `selfupdate` `self-update` `selfupdate-cvs` `selfupdate-git` `selfupdate-rsync` `selfupdate-svn` `selfupdate-finish` | 替换 `$prefix/lib/perl5` 与 `bin` |
| 其它 | `cleanup` `configure` `bootstrap` `update-all` | 删缓存 / 写配置 / 自举 |

这些命令在无终端时会**干净地失败**，不会挂着：

```
$ finx install tree
sudo: a password is required
[exit 1]
```

`remove`、`selfupdate` 同样。

> 本机无法在没有密码的情况下跑完这 30 条，所以它们的「能装能卸」不是本文实测的。
> 已有的旁证：`bootstrap` 在本机装过 40 个包且零 `dpkg: error`；本机前缀里 43 个包
> 是装出来的；`apt 0.5.4` / `tree v2.3.2` 都可用。

---

## 四、两处与判据不符（已修）

统计过程中撞见两个真缺陷，都已在同一提交里修掉，修法与回归测试写在这里。

### 1. `plugins` 标着不需要 root，实际会失败（已修）

命令表里 `plugins` 的 root 位是 0，但普通用户下（修复前）：

```
$ finx plugins
Notification Plugins:
    Growl           1           Growl on-screen notification
…
Failed: can't write temporary file: Permission denied at …/Fink/Config.pm line 629.
```

栈：

```
Fink::Config::save                          Config.pm:629
Fink::SelfUpdate::git::system_check         SelfUpdate/git.pm:80
Fink::SelfUpdate::list_plugins              SelfUpdate.pm:536
Fink::Engine::cmd_listplugins               Engine.pm:453
```

原因在 `SelfUpdate/git.pm`（`svn.pm` 同）：

```perl
$config->set_param("GitPath", $gitpath);
$config->save;          # 无条件写回 $prefix/etc/finx.conf
```

`list_plugins()` 会对每个自更新插件调 `system_check()`，于是**列插件**变成了
**写配置**。配置文件归 root，普通用户写不了。

**修法**：不改 `plugins` 的 root 位（列插件本来就该只读），而是让写配置这一步
变成可选的。`Fink::Config` 新增 `can_save()`，`git.pm` / `svn.pm` 改成：

```perl
$config->set_param("GitPath", $gitpath);
$config->save if $config->can_save;
```

探测到的路径已经在**本进程里**生效，落盘只是为了下次省掉探测，所以写不进去不算错。
`can_save()` 判的是**目录**可写而不是文件可写 —— `save()` 靠 `rename` 覆盖，只读的
配置文件在一个可写目录里照样存得进去，真正的失败是「root 建的目录，普通用户跑」。
`save()` 自己的硬失败保持不变：`configure` 这类命令写不进去仍然要死。

**实测**：同一个 root-owned `/opt/finx/etc/finx.conf`，修复前 `Permission denied`，
修复后 `finx plugins` 列出全部插件、`exit 0`。

**回归测试**：`test/Config/can_save.t`（4 条断言：可写、目录只读、无路径、
`save()` 仍会硬失败）。

### 2. 提权只带 `PERL5LIB`，代理变量会被丢掉（已修）

`Engine.pm:421-432`（修复前）：

```perl
my $method = $config->param_default("RootMethod", "sudo");
if ($method eq "sudo") {
    my $env = '';
    foreach (qw/ PERL5LIB /) { ... }        # 只有这一个
    $cmd = "/usr/bin/sudo $env $cmd";
}
```

`sudo` 会清空环境，所以 finx 用 `/usr/bin/env` 把 `PERL5LIB` 显式送过去。但
`http_proxy` / `https_proxy` / `all_proxy` **没有同样处理**，而 `apt` 与下载都
在提权之后的那个进程里跑。在内网或走镜像的机器上，`finx install tree` 会在输密码
之后突然连不上，看起来像是「网络坏了」。

这一点安装器做得更周全（`finx-install` 的注释里写着「sudo resets the environment,
so they are passed explicitly」），CLI 这一侧没有对称处理。

**修法**：把这段提成 `Fink::Engine::root_env_prefix()`，白名单扩为
`PERL5LIB` 加七个代理变量（大小写两种拼写都送，`curl` 与 `apt` 认的不是同一套），
值里的单引号按 shell 规则转义（代理口令里可能有 `'`），其余一切照旧走
`/usr/bin/env` 过 `sudo` 边界。

**回归测试**：`test/Engine/root_env.t`（7 条断言：空环境、两套拼写并存、
口令里的单引号被转义而不是被丢掉、无关变量不被带过去）。

### 没有一起改的

`RootMethod: su` 那条分支（`/usr/bin/su root -c '…'`）同样会丢代理变量，而且
它把整条命令塞进单引号里，要安全地加 env 前缀得先重做那层引号。`sudo` 是默认值，
`su` 是少数派用法，这轮不动，先记在这里。

---

## 五、常见用法

| 场景 | 写法 |
| --- | --- |
| 装包 | `finx install tree` —— 不要自己加 `sudo`，finx 会问密码 |
| 只在脚本里跑、不想交互 | 需要免密 sudo（`RootMethod: sudo`），否则装包类命令无法自动化 |
| 查东西 | `finx list` / `apropos` / `describe` / `show-deps`，全程不需要 root |
| 校验包描述 | `finx validate foo.info`，不需要 root |
| 列插件 | `finx plugins` —— 目前需要能写 `$prefix/etc/finx.conf`，见第四节 |

`RootMethod` 可选 `sudo` 或 `su`，其他值直接死：

```perl
} else {
    die "Fink is not configured to become root automatically.\n";
}
```

---

## 六、相关文档

- 为什么前缀必须是 `/opt/finx`、以及安装器怎么拒绝别处：[`PREFIX.md`](./PREFIX.md)
- 装完之后前缀里有什么：[`Structure.md`](./Structure.md)
