# AGENTS.md

给在本仓库工作的编码代理（Codex、Claude Code、Copilot 等）与接手维护者的项目约定。

## 术语

| 名词 | 指什么 |
| --- | --- |
| **Fink** | 上游旧项目。历史代码、包描述、`NEWS` 里的写法一律保留原样。 |
| **Finx** | 本项目（`Fincote/Finx`）。x 取「扩展」之意：保留 Fink 的 dpkg/apt 内核，扩展的是安装前缀、文档与可维护性。 |

不要混用：讲设计决策时用 Finx，讲历史、兼容与遗留写法时用 Fink。
代码里的标识符仍是 `fink`（命令名、包名、`Fink::` 命名空间），这是刻意保留的，
不在重命名范围内。

## 与用户交流

- **和用户说话一律用中文**：回复、澄清提问、总结、报错解释都是。
- 代码标识符、命令、路径、终端输出保持原样，不要为说中文而翻译它们。
- **程序面向用户的输出保持英文**（`print_breaking`、各脚本的 `echo`）。中文只出现在
  注释、文档与对话里。

## 安装前缀

**唯一规范前缀是 `/opt/finx`。**

- 新增代码不要写 `/sw` 或 `/opt/sw`。要引用前缀时优先用 `$basepath`、`%p`、`@PREFIX@`。
- 全仓库只有一处**必须**硬编码它：`Fink::Config::bindist_check_prefix`。
  二进制包不可重定位，只能用「与官方构建时逐字相等的前缀」来判定。
- 包描述里出现硬编码前缀会被 `Fink::Validation` 判为不合规，详见
  [`docs/PREFIX.md`](./docs/PREFIX.md)。

## 代码风格

- **Perl 用 tab 缩进，宽度 4** —— 这是 [`STYLE`](./STYLE) 的原文（"tabs are 4 wide"、
  "use tabs for indention of statements"）。仓库实测 2047 行 tab 缩进、0 行空格缩进。
  不要"顺手"把 tab 改成空格。
- **Shell 在仓库里是混的**：`install.sh` 以 tab 为主，`setup.sh` 以 2 空格为主，
  `pathsetup.sh.in` 两者都有。所以：改既有脚本就跟随该文件已有的风格；
  `finx-install/` 下的新脚本统一用 4 空格。
- `#!/bin/sh -e` 还是 `#!/bin/bash` 按原文件，不要统一。
- 唯一权威是仓库根的 [`STYLE`](./STYLE)（纯文本，2003 年的邮件原文）。
  `Style.md` 是给 GitHub 看的副本，两者内容应当一致。
  它只管 Perl；`.vscode/settings.json` 已按它把 `[perl]` 钉成 tab，不要改回空格。
- 不要为了让 `git diff` 好看去重排缩进；只改你要改的行。

## 测试

完整方法见 [`docs/TECHNICAL-GUIDE.md`](./docs/TECHNICAL-GUIDE.md) 第九节。要点：

```
make test          # manifest_check → test_setup → 跑完 t/ 全部测试
```

- 基线：**48 个测试文件、1059 项断言**全通过。
- `make test` 会先跑 `manifest_check`，它校验两件事：仓库里每个文件都在 `MANIFEST`
  里（否则不会进发行 tarball），且生成物都被 `MANIFEST.SKIP` 排除。
  新增需要随程序分发的文件要登记进 `MANIFEST`；生成物则加进 `MANIFEST.SKIP` 与
  `.gitignore` 两处。
- 只想跑测试、跳过完整性检查时用 `make test_setup` 再按 `t/` 的方式驱动。
- 改 `PkgVersion` / `Engine` / `Services` / `Bootstrap` 后必须重跑全套；只改文档不用跑。
- VS Code 里有同名任务：`Test: perl suite`、`Verify: all`（见 `.vscode/tasks.json`）。

安装器（`finx-install/`）另有一套沙箱自测，**手工验证时必须带测试根**：

```
./finx-install/selftest.sh                            # 自建临时根，全程离线
FINX_TEST=/tmp/finx-check ./finx-install/install.sh --dry-run
```

`FINX_TEST` 会把默认前缀变成 `<根>/opt/finx`、把 `TMPDIR` 挪进 `<根>/tmp`，
并拒绝指向根外的 `--prefix`。不带它，默认前缀就是真实的 `/opt/finx`。

## 不要动

- `NEWS`：历史发布记录。即使里面写着 `/sw`、`/opt/sw` 也不改，改了就成伪造历史。
- `install.sh`、`mirror/install.sh`：是「每个包的安装阶段脚本」这一约定的成员
  （`.info` 的 `InstallScript` 写 `./install.sh`），不是用户安装器。改名要同时改
  `MANIFEST`、`Bootstrap::check_files`、`inject.pl` 与外部 tarball，做不全就装不上。
  面向用户的安装器在 `finx-install/`，见 TECHNICAL-GUIDE 8.7。
- **不要**把 `/opt/finx` 或任何系统前缀 `chown` 给调用安装器的用户。
  `fink install` 的 `rootflag` 是 1，chown 免不了密码；而 dpkg 以真 root 执行 `postinst`，
  用户可写的前缀等于把 root 交出去。理由与替代方案见 TECHNICAL-GUIDE 8.6。
- `finx-install/standalone.sh`：生成物，不要手改。改 `finx-install/lib/` 或
  `finx-install/install.sh` 后必须跑 `./finx-install/build-bundle.sh`，否则线上那条
  `curl | bash` 跑的还是旧逻辑。`build-bundle.sh --check` 负责发现漂移。
- `10.9-libcxx/*.patch` 与 `10.9-libcxx/dpkg.patch`：上游源码的补丁载荷，动一个字节就装不上。
- `MANIFEST`：tar 打包清单。只有新增「要随程序分发的文件」才加进去；
  `.md` 已被 `MANIFEST.SKIP` 的 `\.md$` 自动排除，文档不必登记。
- `Release`、`REVISION`、`VERSION`：与发布流程绑定，改前先读 TECHNICAL-GUIDE 第一节。
