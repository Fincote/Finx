# 输出的调试与改色

> 适用 `1.0.0-beta4`。改颜色只需动一个文件；找「这行字是谁打的」需要知道三层来源。

---

## 一、先分清三层来源

`finx` 的输出不是一种东西。改哪个文件，取决于这行字属于哪一层：

| 层 | 谁在说 | 现在有颜色吗 | 要改它得动 |
| --- | --- | --- | --- |
| **我们的话** | `print_breaking` 打印的摘要、警告、错误 | 可以（`${name}` 标记） | 调用点的字符串 + `Fink::Color` |
| **外部命令的回显** | `execute` 把要跑的命令打出来（`sudo … sh -c …`，整行压暗）、失败时的 `==> Failed: execution of …` | 回显压暗；失败那行红色箭头 + 红字 | `perlmod/Fink/Services.pm` 的 `_print_command` 与 `_run_prefixed` |
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
| 每条外部命令的回显与失败 | `perlmod/Fink/Services.pm:556` `_print_command` / `:640`（`execute` 内） |
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

## 六点五、`==>`：一步的样子

摘要、提问、子进程的输出都用同一个记号开头：

```
==> The following package would be installed:
    ncdu
==> The following additional package would be installed:
    libncursesw5-shlibs

==> Do you want to continue? [Y/n]
```

| 元素 | 规则 |
| --- | --- |
| 箭头颜色 | 正常 <span>绿</span>（`ok`）；删除类命令 <span>橙</span>（`orange`）；失败 <span>红</span>（`error`） |
| 箭头右侧的文字 | 默认前景色 + 加粗（`${bold}`）。**不用真黑色** `\033[1;30m`：深色主题上黑字会糊进背景 |
| 列表项 | 四个空格缩进，正好落在箭头右侧文字的起始列 |
| 折行的续行 | 同样缩进四列，所以一个折行的步骤仍是一块 |

箭头的颜色是**进程级状态**，不是逐次传参：一步操作的输出会跨三个模块
（`Engine` 打摘要、`Services` 打子进程输出、`PkgVersion` 报失败），把颜色名
一层层传下去会把签名弄脏，而且漏传一处就少一片颜色。`Engine::process` 在
认出命令之后设一次：

```perl
Fink::Color::set_step_role($removal{$cmd} ? 'orange' : 'ok');
```

用法：`&print_step("…")`（`Fink::CLI`），或者自己拼
`Fink::Color::step_prefix()` 的标记串。`step_prefix` 用的是 `${…}` 而不是
`%{…}`：`print_breaking` 见到 `${` 就跳过 `style_diagnostic`，否则
「Failed: …」会被判定成诊断，把 🧩 顶到箭头前面变成「🧩 ==> Failed: …」。

**提问默认不认回车。** `finx install` 的那一问传了 `require_answer => 1`：直接
回车不算数，会再问一次 `Please answer y or n [Y/n]`。其它 `prompt_boolean`
调用点保持原样（回车取默认值）。

### 子进程的输出也被接管了

每一条子进程输出前面也有箭头：

```
==> Selecting previously unselected package ncdu.
==> Unpacking ncdu (1.22-1) ...
==> Setting up ncdu (1.22-1) ...
```

这是靠 `Services::_run_prefixed` **接管**子进程的 stdout 做到的 —— 只有拿到管道
才能逐行加前缀。三个实际代价：

1. 子进程看到的 stdout 不再是终端，`make` / 编译器可能不再输出颜色，`configure`
   一类的进度也可能按块到达而不是逐行；
2. stderr 被并进 stdout（在 fork 出来的子进程里做 `>&=`），否则两股输出各写各的，
   同一条前缀下会混行；
3. 退出码靠 `close $fh` 之后的 `$?` 传回，与 `system()` 的取法一致 —— 传错一次，
   构建失败就会被当成成功。

`--logfile` 打开时 STDOUT 已经不是终端，前缀里因此没有转义码，日志是干净的。

---

## 七、诊断消息：红色 + 🧩

全项目的 `ERROR:` / `WARNING:` 有三十多处，散在六个模块里。要求每个调用点自己
记得上色、自己打标记，迟早会漏 —— 而漏掉的往往是最少走到的那条。

所以这件事**只在一处做**：`Fink::CLI::print_breaking` 在折行之前先过一遍
`Fink::Color::style_diagnostic`。

```
调用点写的：  "ERROR: apt-get could not be run"
渲染出来的：  🧩 ERROR: apt-get could not be run     ← error 红（WARNING 是黄）
```

| 规则 | 为什么 |
| --- | --- |
| 只认段首的 `ERROR` / `Error` / `FATAL` / `Failed` / `WARNING` / `Warning` | 那是项目里既有的写法，`grep`、测试断言、通知正文全都不受影响 —— 颜色是渲染期才加的 |
| 空行分隔的**每段**都加标记 | 只给第一段加的话，下面几段看着像别人的输出 |
| 已经带 `${name}` 标记或转义码的消息**原样返回** | 作者自己排过色了；再包一层 `error` 会把 `${reset}` 之后的文字染红 |
| 其它消息原样返回 | 满屏都是标记等于没有标记 |

标记本身是 `Fink::Color::$PROG_MARK`，与 MacWave 的 🌊 同位。它是**字节串**
（`"\xF0\x9F\xA7\xA9"`），不是 `"\x{1F9E9}"` —— STDOUT 没有 `:utf8` 层，宽字符
会打一条 `Wide character in print` 把输出弄脏。`install.sh` 里另有同名的
`MARK` 常量（bash 直接写字面量），两处要一起改。

`die` 的消息也能带上：它经 `Engine::process` 的 `$@` 处理，最终走
`print_breaking("Failed: …")`，同样自动上色。`die_breaking` 直接把消息交给
`print_breaking_stderr`，也是自动的。

安装器（`finx-install/install.sh`）是 bash，用不了 Perl 模块，但 `die()` /
`warn()` 是它所有 stderr 提示的**唯一**出口，改那两个函数就够了。另有两处
「还没读到函数定义就得报错」的早期校验，直接用了 `${RED_BOLD}${MARK} ERROR: …`。

调试：

```sh
perl scripts/color_preview.pl | sed -n '/diagnostic/,+4p'     # 关闭上色
FINX_COLOR=1 perl scripts/color_preview.pl | cat -v            # 看真实转义码
```

---

### Ctrl+C 也是一条消息

默认的 SIGINT 作用在 perl 上是「当场结束」：屏幕上什么都不留，用户看到的是编译
到一半的目录和一个没有解释的提示符 —— 与「命令跑完了」长得一样。Shell 脚本能靠
`$?` 分辨（130），人不能。

所以统一成一句话加一个退出码，与 MacWave 的 `wave.py` 一致：

```
$ finx install ncdu
   ...
^C
🧩 Operation cancelled by user.        ← 走 STDERR
$ echo $?
130
```

实现分三层，缺一层就会漏：

| 层 | 做什么 |
| --- | --- |
| `finx.in`（进程开头） | `Fink::CLI::install_interrupt_handler()` —— 只做一件事：`die "User interrupt.\n"` |
| `Engine::process`（命令执行块） | 外面本来就有 `local $SIG{INT}`；捕获后 `Fink::CLI::interrupted($@)` 判一下，是中断就 `exit report_interrupt()` |
| `finx.in`（兜底） | Engine 没接住的（例如已经在 `scanpackages` 里）由顶层的 `eval` 接住，同样 `exit 130` |

`interrupted()` 存在的原因：`$@` 里那个字符串要在三处比较，而**只在程序里出现一次
的包变量**会被 `use warnings` 当成笔误，打一条 `Name "…" used only once` 到每次
运行的 stderr 上。

中断**不算失败**：不走 `Failed:` 分支，也不触发 `finkDoneFailed` 通知 —— 用户主动
停下不该被报成错误。`$INTERRUPT` 的措辞也别改，`Fink::Scanpackages` 用
`/User interrupt/` 区分「用户停的」与「真出错，可以降级成警告」。

---

### 这些消息用什么语言

英文。唯一的例外是 `finx-install/install.sh`，它中英成对（`t 'english' '中文'`，
`--zh` 或 `FINX_LANG=zh` 取中文）—— 那是用户装东西之前、手上还没有 `finx --help`
和 man 页的地方。

新写的 `print_breaking` 消息、`die` / `warn` 文案、`--help` 文本都用英文；中文留在
注释、文档与对话里。完整的规则与「为什么 POD 也不能写中文」（`pod2man` 会让整个
安装中止）见 `AGENTS.md` 的「与用户交流」。

---

## 八、什么时候不上色

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

## 九、打错命令 / 打错旗标

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
🧩 Error: Unknown command or argument.

   finx instll jq
        ^^^^^^

🧩 Did you mean: finx install jq

   instll is not a command. The one you want is install.

   For the full list: finx -h
```

```
$ finx mirror --jsons=1
🧩 Error: illegal option --jsons for `finx mirror`

   finx mirror --jsons=1
               ^^^^^^^

🧩 Next: Did you mean --json?

🧩 finx mirror --help lists the flags this command accepts
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

## 十、还没上色的地方（知道就行，别以为是 bug）

| 位置 | 为什么没有 |
| --- | --- |
| 子进程输出的**正文** | 只有箭头带颜色，正文原样 —— `make` / `gcc` 自己决定怎么排版，全涂一种颜色只会更难读 |
| `curl` 的进度条 | 第三方工具自己的输出 |
| `configure` 的交互提问 | `Fink::CLI::prompt_*` 的排版是另一套（`(1)\t选项`），目前不上色 |
| `finx mirror --json/--raw` | 机器可读的输出，故意不掺转义码 |

`execute` 那一层已经处理过了，形状不一样：

- **回显**（`sudo -u fink-bld [env] sh -c '…'`）整行压暗，让子进程自己的输出更
  醒目。走 `Fink::Color::colorize('%{dim}…%{reset}')` 而不是 `print_breaking`：
  一次构建几千行，不值得每行走一遍折行包装。关闭上色时逐字节不变。
- **子进程的每一行输出**都加 `==> `（见第六点五节）。
- **失败那一步**是 `==> Failed: execution of <命令>, exit code <N>`，箭头与文字
  都是 `error` 色，**不带 🧩** —— 箭头已经承担了「这是哪一行」的职责。原来的
  `### execution of …` 不以 `Failed` 开头，`style_diagnostic` 认不出来，所以
  那句一直是素的。

注意这两套记号的分工：**`==>` 标「一步」**（包括失败的那一步），**🧩 标「一条
诊断」**（`ERROR:` / `WARNING:` 之类）。同一条消息只该有其中一个。

---

## 十一、一次改动的检查清单

```sh
perl scripts/color_preview.pl | cat        # 关闭时无转义码
perl scripts/help_preview.pl --width 60    # 帮助的排版/折行
perl scripts/install_preview.pl --fail     # 安装流程的全部输出
FINX_COLOR=1 perl scripts/color_preview.pl | cat -v   # 打开时颜色对得上
make test                                  # 含 test/CLI/color_tokens.t
make format                                # Perl 用 tab，shell 用 4 空格
```

新增 Perl 文件记得同时登记 `MANIFEST`（否则不会进载荷 tar），并跑 `bash scripts/structure_test.sh` 交叉核对。
