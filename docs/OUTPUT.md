# 输出的调试与改色

> 适用 `1.0.0-beta2`。改颜色只需动一个文件；找「这行字是谁打的」需要知道三层来源。

---

## 一、先分清三层来源

`finx` 的输出不是一种东西。改哪个文件，取决于这行字属于哪一层：

| 层 | 谁在说 | 现在有颜色吗 | 要改它得动 |
| --- | --- | --- | --- |
| **我们的话** | `print_breaking` 打印的摘要、警告、错误 | 可以（`${name}` 标记） | 调用点的字符串 + `Fink::Color` |
| **外部命令的回显** | `execute` 把要跑的命令打出来（`sudo … sh -c …`）、失败时的 `### execution of … failed` | 无 | `perlmod/Fink/Services.pm` 的 `execute` |
| **子进程自己的话** | 编译器、`make`、`dpkg -i`、`curl` 进度条、`patch` | 无，也不该有 | 不归我们管 |
| **帮助** | `finx --help` / `finx <cmd> --help` | 有，但走另一套 | `perlmod/Fink/Help.pm` |

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
| 安装/更新摘要、additional packages、可能被临时移除的包 | `perlmod/Fink/Engine.pm` 的 `real_install`，约 `:2320`–`:2365` |
| 阶段失败（`phase compile: foo failed`） | `perlmod/Fink/PkgVersion.pm:5697` `package_error` |
| 每条外部命令的回显与失败 | `perlmod/Fink/Services.pm:613`–`:635`（`execute` 内） |
| `--help` 的排版、对齐、宽度 | `perlmod/Fink/Help.pm` 的 `align_option_text`；模板在各 `cmd_*` 的 `helpformat` |

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

## 五、帮助是另一条路：`Fink::Help`

`finx --help` **不经过** `print_breaking`，所以它既没有 `${name}` 标记，也不吃
`wrap_marked` 的折行。整条链是：

```
Config.pm::parse_options        ← 全局帮助的选项表 + helpformat（:263）
Engine::cmd_*                   ← 子命令各自的 get_options(..., helpformat => …)
  └ Fink::Services::get_options ← 只用 Getopt 解析，然后 print expand_help(...)
      └ Fink::Help::expand_help ← 展开 %intro/%all/%opts/%align
          ├ option_help         ← 一个选项 → usage + 描述
          ├ option_usage        ← -f, --full=VALUE
          ├ align_option_text   ← 按终端宽度折行、按未上色长度补空格
          └ paint / paint_label ← 按角色取 %PALETTE 里的转义码
```

设计上分成两个模块：**解析**在 `Fink::Services::get_options`，**渲染**在
`Fink::Help`（对应 MacWave 的 `lib/help.py`）。帮助的颜色是直接产出转义码
（`paint`），所以模板本身保持纯文本。

调排版时不必跑真实命令：

```sh
perl scripts/help_preview.pl                 # 按终端宽度渲染一份假帮助
perl scripts/help_preview.pl --width 40      # 折行最窄的样子
perl scripts/help_preview.pl | grep -c $'\033'   # 关闭上色时应为 0
FINX_COLOR=1 perl scripts/help_preview.pl --width 60 | cat -v
```

两个常调的旋钮：全局的 `optwidth => 23`（`Config.pm`），命令表的
`$comlen = 14`（`Config.pm`）。

---

## 六、一眼看完安装流程的输出

改「安装时说什么」最烦的是每一步都要真装一遍才知道好不好看。`scripts/install_preview.pl`
把 `finx install <pkg>` 的输出**按顺序重放**：不联网、不提权、不写文件。

```sh
perl scripts/install_preview.pl                # 按终端宽度重放
perl scripts/install_preview.pl --width 60     # 调折行用这个
perl scripts/install_preview.pl --fail         # 追加「编译失败」那一段
FINX_COLOR=1 perl scripts/install_preview.pl | cat -v   # 看真实转义码
```

它复用的是真实的 `print_breaking` 与 `${name}` 标记，所以折行、缩进、颜色与真机
一致；编出来的只是「命令本身」（`tar` / `patch` / `make` / `dpkg`）—— 那一层是
子进程输出，本来就不归我们管。

脚本里的文案是抄来的，靠 `test/Install/preview_matches_source.t` 两头钉住：关键词
既要在 `Engine.pm` / `PkgVersion.pm` / `Services.pm` 里，也要在预览输出里。改了真
代码而没同步预览，测试会红。

想看**真实**的计划（不是重放），用 `finx install --dry-run <pkg>`：它会解依赖并打印
摘要，然后停下。

---

## 七、什么时候不上色

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

## 八、打错命令 / 打错旗标

两条路，同一个形状（照 MacWave 的 `print_error_help`），渲染都在 `Fink::Help`：

| 场合 | 入口 | 渲染 |
| --- | --- | --- |
| 子命令名打错 | `Engine::process` 的 `_unknown_command_message` | `Fink::Help::unknown_command_message` |
| 旗标打错 | `Services::get_options` 的 `_unknown_option_exit` | `Fink::Help::unknown_option_message` |

两段提示都由三部分组成：**回显用户真实输入的那一行**、用 `^` 指住出错的词、
给改法（猜得到才给）。猜不到也照样回显并指出是哪个词 —— 那是唯一的定位信息。
**任何情况下都不打印整篇帮助**：几十行会把有用的两行冲掉，想知道全部命令的人
自己会敲 `finx -h`。

```
$ finx instll jq
finx: Error: Unknown command or argument.

   finx instll jq
        ^^^^^^

finx: Did you mean: finx install jq

   instll is not a command. The one you want is install.

   For the full list: finx -h
```

```
$ finx mirror --jsons=1
finx: Error: illegal option --jsons for `finx mirror`

   finx mirror --jsons=1
               ^^^^^^^

   Next: Did you mean --json?

   finx mirror --help lists the flags this command accepts
```

颜色与普通消息同一套 `%PALETTE`：`Error:` 行与出错的那个词、脱字符用 `error`，
改法里的正确写法用 `ok`，指路用的命令名用 `cmd`。旗标错误**只给旗标名**上色和
打 `^`，`=12s` 的值部分留着原样 —— 错的是名字，不是值。

回显用的是用户真实输入（含全局旗标，如 `finx -v instll`），取自
`Fink::Config` 的 `_ARGV_stack`；拿不到时才退化成「命令 + 参数」。

`^` 的缩进按**未上色**的长度算（逃逸码零宽但计入 `length`），这条有测试钉着
（`test/Engine/unknown_command.t`、`test/Engine/unknown_option.t`）。

### 一个没改的取舍：Getopt 的前缀缩写仍然有效

`Getopt::Long` 默认允许无歧义缩写，所以 `finx --verbos` 会被当成 `--verbose`，
轮不到「打错旗标」这条提示。要严格就加 `no_auto_abbrev`，但那会让现存脚本里
的缩写失效，所以没动。

---

## 九、还没上色的地方（知道就行，别以为是 bug）

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

## 十、一次改动的检查清单

```sh
perl scripts/color_preview.pl | cat        # 关闭时无转义码
perl scripts/help_preview.pl --width 60    # 帮助的排版/折行
perl scripts/install_preview.pl --fail     # 安装流程的全部输出
FINX_COLOR=1 perl scripts/color_preview.pl | cat -v   # 打开时颜色对得上
make test                                  # 含 test/CLI/color_tokens.t
make format                                # Perl 用 tab，shell 用 4 空格
```

新增 Perl 文件记得同时登记 `MANIFEST`（否则不会进载荷 tar），并跑 `bash scripts/structure_test.sh` 交叉核对。
