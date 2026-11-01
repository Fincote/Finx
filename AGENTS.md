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
  "use tabs for indention of statements"）。
- **Shell 用 4 空格** —— `STYLE` 只管 Perl；shell 此前没有规矩，统一成 4 空格。
- 唯一权威是 [`STYLE`](./STYLE)（Perl，纯文本，2003 年的邮件原文）与
  [`scripts/format_check.pl`](./scripts/format_check.pl)（两者，可执行）。
  [`.editorconfig`](./.editorconfig) 让编辑器跟随同一套规则。
- 提交前跑：

  ```
  make format                          # 检查
  ./scripts/format_check.pl --fix      # 修正
  ```

  `make format` **故意不挂进 `make test`**：bootstrap 会跑 `make test`，格式瑕疵
  不该拦住安装。
- 检查器有两类例外，因为它们不是缩进：heredoc 正文、跨行引号内的续行、
  POD 块、`__END__` 之后。另外 `update/config.guess`、`config.sub`、`ltconfig`
  与三个 CPAN 派生模块整体不检查。细节见脚本头部注释。
- `#!/bin/sh -e` 还是 `#!/bin/bash` 按原文件，不要统一。
- 不要为了让 `git diff` 好看去重排缩进；要重排就跑 `scripts/format_check.pl --fix`。

## 测试

完整方法见 [`docs/TECHNICAL-GUIDE.md`](./docs/TECHNICAL-GUIDE.md) 第九节。要点：

```
make test          # manifest_check → structure → sources_check → test_setup → 跑完 t/ 全部测试
```

- 基线：**48 个测试文件、1059 项断言**全通过。
- `make test` 会先跑 `manifest_check`，它校验两件事：仓库里每个文件都在 `MANIFEST`
  里（否则不会进载荷 tar），且生成物都被 `MANIFEST.SKIP` 排除。
  新增需要随程序分发的文件要登记进 `MANIFEST`；生成物则加进 `MANIFEST.SKIP` 与
  `.gitignore` 两处。
- 接着跑 `structure`（[`scripts/structure_test.sh`](./scripts/structure_test.sh)）：
  在临时目录里建「只有 git 文件的树」与「只有 MANIFEST 文件的树」，各跑一遍
  `setup.sh` + `install.sh`，两边的安装结果必须逐字节一致。
  它守的是 `MANIFEST` 与实际安装是否同步 —— `manifest_check` 只看得见 `MANIFEST`
  一侧，看不见 `install.sh` 到底装了什么。改了 `install.sh` 的文件列表或
  `MANIFEST` 后务必跑一次。
- 再跑 `sources_check`（[`base-files/pack.sh`](./base-files/pack.sh) `--check`）：
  确认现场打出的 `base-files` tar 与 [`base-files/pack.conf`](./base-files/pack.conf)
  里登记的 `source-md5` 一致，并且在仓库里还要求 `.info` 的 `Source-MD5` 与之一致。
  **改了 `base-files/` 里任何一个载荷文件都要跑 `./base-files/pack.sh --update`**，
  否则自举时 Fink 会认为 tar 被篡改并停下来问人。背景见 TECHNICAL-GUIDE 8.9。
- `make payload_test`（[`scripts/payload_test.sh`](./scripts/payload_test.sh)）是独立的，
  **不在 `make test` 里**：它只把 `MANIFEST` 列出的文件复制到临时目录，在那儿再跑一遍
  `make test`。这正是 `fink.info.in` 的 `CompileScript` 执行时的环境 —— 没有
  `10.9-libcxx/`、没有 `.git`。任何「只在仓库里成立」的假设都会在这一步暴露，
  而本地 `make test` 是绿的。改了 `Makefile`、`MANIFEST` 或任何构建期脚本后要跑。
- 只想跑测试、跳过完整性检查时用 `make test_setup` 再按 `t/` 的方式驱动。
- 改 `PkgVersion` / `Engine` / `Services` / `Bootstrap` 后必须重跑全套；只改文档不用跑。
- VS Code 里有同名任务：`Test: perl suite`、`Test: payload tree`、`Verify: all`
  （见 `.vscode/tasks.json`）。

安装器（`finx-install/`）另有一套沙箱自测，**手工验证时必须带测试根**：

```
./finx-install/selftest.sh                            # 自建临时根，全程离线
FINX_TEST=/tmp/finx-check ./finx-install/install.sh --dry-run
```

`FINX_TEST` 会把默认前缀变成 `<根>/opt/finx`、把 `TMPDIR` 挪进 `<根>/tmp`，
并拒绝指向根外的 `--prefix`。不带它，默认前缀就是真实的 `/opt/finx`。

### CI

`.github/workflows/verify.yml` 是 `Verify: all` 的线上版：覆盖它的全部七步、顺序一致，
另加「断言工具链」「选定架构」与「跑完工作区必须干净」三条只对 CI 有意义的检查。
细节见 TECHNICAL-GUIDE 9.1。两条规矩：

- **日常只有 GitHub Actions 一条流水线。** 本仓库是公开仓库，Actions 的标准 runner
  不计费，而 CircleCI 的免费层是共享的 2.5 万 credits/月、macOS executor 最贵。
  不要为了"多一层保障"把它接成第二条常驻流水线 —— 那会重新引入额度问题。
- **`.circleci/config.yml` 是备用方案，默认惰性。** 它在 CI 后台 Add Project 之后才
  可能跑，而且刻意用 `filters` 限成只认 `ci-*` / `ci-bootstrap-*` 标签，普通 push 与
  PR 一概不触发。它不复制任何逻辑：`make` 目标与 `scripts/ci_bootstrap.sh` 与
  GitHub 共用同一份。要启用、要换成常驻，见该文件头部注释。
- **本机绿了再推**。CI 的职责是复核，不是第一次验证。新增或修改测试时先在本地跑
  对应的那一两条（`make test` / `./finx-install/selftest.sh`），再把整条
  `Verify: all` 过一遍。

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
- **`MANIFEST` 是载荷清单，不是发行清单。** 它只列「要打进载荷 tar 的文件」；
  `fink.info.in`、`10.9-libcxx/`、`mirror/` 被 `MANIFEST.SKIP` 排除是**刻意**的 ——
  前者的用途是生成包描述，后者由 bootstrap 单独 `cp`。`Bootstrap::check_files`
  查的是另一件事（源码树完整性），两者不同集，不要套包含关系。
  这条曾被我判断错，纠正过程见 TECHNICAL-GUIDE 10.5。
- `Release`、`REVISION`、`VERSION`：与发布流程绑定，改前先读 TECHNICAL-GUIDE 第一节。
- `base-files/` 是从上游 `fink/base-files` 收进来的包源码，见
  [README](./base-files/README.md)。它与 `10.9-libcxx/base-files.info` 里写死的
  `Source-MD5` 绑定，改任何一个载荷文件后必须跑 `./base-files/pack.sh --update`，
  否则自举会卡在「校验和不符」。
- **种子的 tar 包不进仓库。** git 单文件 100 MiB 硬限，种子是编译产物，放进去会让
  历史永久膨胀且无法删除。产物发到 GitHub Releases，清单留在 `finx-install/seed/`
  并由 git 记录 —— 清单是校验锚点，与被校验的产物不能同源。理由与命名规则见
  TECHNICAL-GUIDE 8.8。
