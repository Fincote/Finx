# 输出的调试与改色

> 适用 `1.0.0-beta1`。改颜色只需动一个文件；找「这行字是谁打的」需要知道三层来源。

---

## 一、先分清三层来源

`finx` 的输出不是一种东西。改哪个文件，取决于这行字属于哪一层：

| 层 | 谁在说 | 现在有颜色吗 | 要改它得动 |
| --- | --- | --- | --- |
| **我们的话** | `print_breaking` 打印的摘要、警告、错误 | 可以（`${name}` 标记） | 调用点的字符串 + `Fink::Color` |
| **外部命令的回显** | `execute` 把要跑的命令打出来（`sudo … sh -c …`）、失败时的 `### execution of … failed` | 无 | `perlmod/Fink/Services.pm` 的 `execute` |
| **子进程自己的话** | 编译器、`make`、`dpkg -i`、`curl` 进度条、`patch` | 无，也不该有 | 不归我们管 |

第三层是直通的：`execute` 用 `system()`，子进程直接继承终端 fd。想给它上色等于去改 gcc 的输出，不做。能做的是**把它收进日志**（`--log-output`），屏幕上只留摘要。

---

## 二、找「这行字是谁打的」

```sh
# 1. 用输出的原文去搜（去掉变量部分，留最独特的一小段）
grep -rn "execution of" perlmod/
grep -rn "would be installed" perlmod/
grep -rn "The following" perlmod/

# 2. 只在输出函数里搜，范围更小
grep -rn "print_breaking" perlmod/Fink/Engine.pm | head -20
grep -rn 'print "' perlmod/Fink/PkgVersion.pm | grep -v '#'

# 3. 连行号一起看上下文
sed -n '2317,2362p' perlmod/Fink/Engine.pm
```

三个高频落点：

| 输出 | 位置 |
| --- | --- |
| 安装/更新摘要、additional packages、可能被临时移除的包 | `perlmod/Fink/Engine.pm` 的 `real_install`，约 `:2317`–`:2362` |
| 阶段失败（`phase compile: foo failed`） | `perlmod/Fink/PkgVersion.pm:5697` `package_error` |
| 每条外部命令的回显与失败 | `perlmod/Fink/Services.pm:609`–`:630`（`execute` 内） |

---

## 三、改颜色：只改一个文件

调色板在 `perlmod/Fink/Color.pm` 的 `%PALETTE`：

```perl
my %PALETTE = (
	reset   => "\033[0m",
	bold    => "\033[1m",
	yellow  => "\033[33m",
	orange  => "\033[38;5;208m",
	# 语义别名：写消息时用这些，读起来是「这是什么」而不是「这是什么颜色」
	step    => "\033[1;38;5;25m",   # 步骤标题的「==>」，与 install.sh 的 BOLD_BLUE 同值
	cmd     => "\033[32m",
	flag    => "\033[36m",
	value   => "\033[33m",
	section => "\033[35m",
	prog    => "\033[38;5;208m",
	pkg     => "\033[1m",
	error   => "\033[1;31m",
	warn    => "\033[33m",
	ok      => "\033[32m",
);
```

改完**不用重新编译**，直接用预览脚本看效果：

```sh
perl scripts/color_preview.pl                 # 终端里看
perl scripts/color_preview.pl | cat           # 重定向后应是纯文本，无转义码
FINX_COLOR=1 perl scripts/color_preview.pl | cat -v   # 强制上色并露出转义码
```

`%PALETTE` 是唯一的定义处：`Services::_paint`、帮助渲染、`print_breaking` 都从这里取。

唯一的例外是 `finx-install/install.sh` —— 它是纯 bash，加载不了 Perl 模块，只能用自己那几个 shell 常量。其中 `BOLD_BLUE`（`==>`）与这里的 `step` 是同一个值，改一处别忘了改另一处；`test/CLI/color_tokens.t` 钉住了 `step` 的值。

---

## 四、给一句话上色：在字符串里放标记

```perl
# 双引号里用 %{name}，不需要转义
&print_breaking("%{bold}The following package would be installed:%{reset}");
&print_breaking("%{pkg}$name%{reset}");

# 单引号里用 ${name}（与 shell 的写法一致）
&print_breaking('${yellow}WARNING${reset}: no Depends field');
```

**为什么有两种写法**：Perl 的双引号会把 `${yellow}` 当成变量插值（`use strict` 下直接编译失败），所以那里只能写 `%{yellow}` 或 `\${yellow}`；而 `%` 不是 sigil，`%{yellow}` 在双引号里原样保留。两种在展开后完全等价。

标记是**零宽**的：`print_breaking` 检测到标记就改走 `Fink::Color::wrap_marked`，按可见列数折行，所以长消息不会因为标记而窄一截。这一点有测试钉着（`test/CLI/color_tokens.t`）。

---

## 五、什么时候不上色

输出不是终端（重定向、管道、CI 日志）时，标记会被**删掉**而不是留下转义码 —— 否则贴进 issue 的日志全是 `^[[33m`，`grep` 也匹配不上。

| 环境变量 | 行为 |
| --- | --- |
| `NO_COLOR=1` | 关（优先级最高） |
| `CLICOLOR=0` | 关 |
| `FINX_COLOR=1` | 开（截图、录屏时输出被重定向仍要颜色） |
| `CLICOLOR_FORCE=1` | 开 |
| 都不设 | 看 STDOUT 是不是终端 |

调试时用 `cat -v` 能看见真实转义码：

```sh
FINX_COLOR=1 finx install --dry-run cvs | cat -v
```

---

## 六、还没上色的地方（知道就行，别以为是 bug）

| 位置 | 为什么没有 |
| --- | --- |
| `execute` 回显的每条命令、`### execution of … failed` | 走的是裸 `print`，没经过 `print_breaking` |
| 编译输出、`make` 的进度 | 子进程直通终端 |
| `curl` 的进度条 | 第三方工具自己的输出 |
| `dpkg -i` 的输出 | 同上 |
| `configure` 的交互提问 | `Fink::CLI::prompt_*` 的排版是另一套（`(1)\t选项`），目前不上色 |
| `finx mirror --json/--raw` | 机器可读的输出，故意不掺转义码 |

要给这些上色，得先决定它们归哪一层：命令回显可以走 `print_breaking`；子进程输出只能靠「收进日志 + 摘要」而不是上色。

---

## 七、一次改动的检查清单

```sh
perl scripts/color_preview.pl | cat        # 关闭时无转义码
FINX_COLOR=1 perl scripts/color_preview.pl | cat -v   # 打开时颜色对得上
make test                                  # 含 test/CLI/color_tokens.t
make format                                # Perl 用 tab，shell 用 4 空格
```

新增 Perl 文件记得同时登记 `MANIFEST`（否则不会进载荷 tar），并跑 `bash scripts/structure_test.sh` 交叉核对。
