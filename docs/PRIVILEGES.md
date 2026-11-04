# 哪些命令需要 root

Finx 把包装进 `/opt/finx`，那个前缀归 `root:wheel`，所以凡是改动前缀的命令都要
root。本文把命令表里的判据、实测结果、以及两处与判据不符的地方写清楚。

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

## 四、两处与判据不符（实测缺陷）

### 1. `plugins` 标着不需要 root，实际会失败

命令表里 `plugins` 的 root 位是 0，但普通用户下：

```
$ finx plugins
Notification Plugins:
    Growl           1           Growl on-screen notification
…
Failed: can't write temporary file: Permission denied at …/Fink/Config.pm line 629.
[exit 1]
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

这不是「报错难看」而已：它让一个本该只读的命令在没有 root 时不可用，而界面上没有
任何提示说要 sudo。

### 2. 提权只带 `PERL5LIB`，代理变量会被丢掉

`Engine.pm:421-432`：

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
在提权之后的那个进程里跑。

这一点安装器做得更周全（`finx-install` 的注释里写着「sudo resets the environment,
so they are passed explicitly」），CLI 这一侧没有对称处理。

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
