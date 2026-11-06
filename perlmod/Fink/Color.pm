# -*- mode: Perl; tab-width: 4; -*-
#
# Fink::Color - 一处定义配色，字符串里用 ${名字} 就地着色
#
# Fink - a package manager that downloads source and installs it
# Copyright (c) 2001 Christoph Pfisterer
# Copyright (c) 2001-2026 The Fink Package Manager Team
# Copyright (c) 2026 Sha0huaZhang <zsh@finx.sh>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110, USA.
#

package Fink::Color;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(enabled colorize paint strip wrap_marked tokens palette);

=head1 NAME

Fink::Color - 一处定义配色，字符串里用 ${名字} 就地着色

=head1 SYNOPSIS

  use Fink::Color qw(colorize);

  print_breaking "${yellow}WARNING${reset}: 这条包描述没有 Depends";

  # 或先拼好再交给任何输出函数
  my $line = colorize('${cmd}install${reset} ${flag}--yes${reset}');

=head1 DESCRIPTION

改颜色只需要动本文件的 C<%PALETTE>；写新消息时不必再记「哪个角色对应哪个
函数」，直接在字符串里放 C<${名字}>。

=head2 为什么不用 ${yellow} 当 Perl 变量

Perl 的双引号里 C<${yellow}> 会去插值一个叫 C<$yellow> 的变量。消息散在十几个
包里，各自都得先声明一遍那些变量；漏一个就是编译期错误，而 C<use strict> 下
连提示都不会给出「你是不是想上色」。所以这里把 C<${名字}> 当**普通文本**看待，
由 C<colorize> 在真正输出前展开 —— 写的人只关心名字，不关心作用域。

=head2 什么时候不上色

输出不是终端（被重定向到文件或管道）、或者 C<NO_COLOR> 被设置时，C<colorize>
把标记**删掉**而不是留下转义码。逃逸码混进日志以后，用户贴报错求助时会变成
一堆 C<^[[33m>，C<grep> 也再也匹配不上。

  环境变量              行为
  NO_COLOR=1            关（优先级最高）
  CLICOLOR=0            关
  FINX_COLOR=1          开（截图、录屏时输出被重定向仍要颜色）
  CLICOLOR_FORCE=1      开
  都不设                看 STDOUT 是不是终端

=head2 折行不会因为标记而变短

标记是零宽的，但 C<length()> 会把它算进去。所以带标记的字符串不能直接交给
C<word_wrap>：那样每出现一个 C<${yellow}> 就少折 9 列，长消息会窄一截。
C<wrap_marked> 按**可见列数**折行，标记原样跟着走，最后才展开。

=head1 已知标记

跑 C<scripts/color_preview.pl> 可以一次看到全部标记的实际效果 —— 调色时
不必改代码、编译、再翻一份长日志去找那一行。

=cut

# 调色板：**改颜色只改这一处**。
#
# 前半是原色名，后半是语义别名。别名存在的意义是让消息读起来是「这是什么」
# 而不是「这是什么颜色」：写 ${error} 比写 ${boldred} 更不容易改错，将来把
# 错误改成别的样式也不用去动每一条消息。
my %PALETTE = (
	# 基础
	reset   => "\033[0m",
	bold    => "\033[1m",
	dim     => "\033[2m",
	underline => "\033[4m",
	red     => "\033[31m",
	green   => "\033[32m",
	yellow  => "\033[33m",
	blue    => "\033[34m",
	magenta => "\033[35m",
	cyan    => "\033[36m",
	white   => "\033[37m",
	orange  => "\033[38;5;208m",

	# 语义
	step    => "\033[1;38;5;25m", # 步骤标题的「==>」，与 install.sh 的 BOLD_BLUE 同值
	cmd     => "\033[32m",        # 子命令名
	flag    => "\033[36m",        # 旗标
	value   => "\033[33m",        # 旗标的值 / 占位符
	section => "\033[35m",        # 一节标题
	prog    => "\033[38;5;208m",  # 程序名
	pkg     => "\033[1m",         # 包名
	error   => "\033[1;31m",
	warn    => "\033[33m",
	ok      => "\033[32m",
);

# 标记形状：${name}，也接受 %{name}。
#
# 为什么两种：
#   ${name}  读起来最像 shell，但 Perl 的双引号会把它当变量插值 —— 必须写成
#            \${name}，或者整串用单引号。消息里常要拼接变量，转义会越来越乱。
#   %{name}  % 不是 Perl 的 sigil，双引号里原样保留，写起来不用转义。
# 两种在 colorize 之后完全等价，`finx mirror`/预览脚本打印的都是展开后的样子。
#
# 名字限定为小写字母开头的词，避免和 shell 的 ${VAR} 混起来 —— 一段话里
# 真出现 ${HOME} 时不会被当成颜色标记。
my $TOKEN_RE = qr/(?:\$\{|%\{)([a-z][a-z0-9_-]*)\}/;

# 已经产生过的未知标记。同一条消息会被打印很多次，警告一次就够，
# 否则屏幕上全是同一句。
my %warned;

# 环境变量指纹 → 开关。缓存是因为 print_breaking 每次输出都会问一遍，
# 而 fork/exec 之外这几项不会变；测试要在同一进程里切换它们，所以按指纹失效。
my $state;

sub enabled {
	my @vars = qw(NO_COLOR CLICOLOR CLICOLOR_FORCE FINX_COLOR);
	my $sig = join "\0", map { defined $ENV{$_} ? $ENV{$_} : "\0undef" } @vars;
	return $state->[1] if $state && $state->[0] eq $sig;

	my $force = grep { defined $ENV{$_} && $ENV{$_} ne '' && $ENV{$_} ne '0' }
		qw(FINX_COLOR CLICOLOR_FORCE);
	my $deny = (defined $ENV{NO_COLOR} && $ENV{NO_COLOR} ne ''
			&& $ENV{NO_COLOR} ne '0')
		|| (defined $ENV{CLICOLOR} && $ENV{CLICOLOR} eq '0');

	my $on;
	if ($deny) {
		$on = 0;
	} elsif ($force) {
		$on = 1;
	} else {
		$on = -t STDOUT ? 1 : 0;
	}
	$state = [$sig, $on];
	return $on;
}

# 全部标记名（给预览脚本与测试用）
sub tokens { return sort keys %PALETTE }

# 标记 → 转义码。未知标记返回 undef，由调用方决定怎么处理。
sub _escape {
	my $name = shift;
	return $PALETTE{$name};
}

# 展开 ${名字}。关闭上色时**删掉**标记，不是留下转义码。
sub colorize {
	my $text = shift;
	return $text unless defined $text && length $text;
	return $text unless $text =~ m{\$\{|%\{};

	unless (enabled()) {
		$text =~ s/$TOKEN_RE//g;
		return $text;
	}

	$text =~ s{$TOKEN_RE}{
		my $name = $1;
		my $escape = _escape($name);
		if (defined $escape) {
			$escape;
		} else {
			warn "Fink::Color: unknown colour token \${$name}\n"
				unless $warned{$name}++;
			'';
		}
	}ge;
	return $text;
}

# 去掉标记与已经存在的转义码，得到「屏幕上占几列」的纯文本。
sub strip {
	my $text = shift;
	return $text unless defined $text;
	$text =~ s/$TOKEN_RE//g;
	$text =~ s/\033\[[0-9;]*m//g;
	return $text;
}

# 一个字符串的可见长度：不含 ${...}，也不含 ANSI 转义。
sub _visible_length {
	my $text = shift;
	$text =~ s/$TOKEN_RE//g;
	$text =~ s/\033\[[0-9;]*m//g;
	return length $text;
}

# 按可见列数折行，标记跟着走，最后统一展开。
#
# 与 CLI::word_wrap 的差别只有一点：这里按可见宽度算，所以 ${yellow}
# 不会让一行短掉 9 列。做法是先把字符串切成「原子」——普通字符宽 1，
# 标记与转义码宽 0 —— 再贪心填行，回退到本行最后一个空格处断开。
sub _atoms {
	my $text = shift;
	my @atoms;
	pos($text) = 0;
	while (pos($text) < length($text)) {
		if ($text =~ /\G($TOKEN_RE)/gc) {
			push @atoms, [$1, 0, 0];
		} elsif ($text =~ /\G(\033\[[0-9;]*m)/gc) {
			push @atoms, [$1, 0, 0];
		} elsif ($text =~ /\G(.)/gcs) {
			my $char = $1;
			push @atoms, [$char, 1, ($char eq ' ' ? 1 : 0)];
		} else {
			last;
		}
	}
	return @atoms;
}

sub _join_atoms {
	my $atoms = shift;
	return join('', map { $_->[0] } @$atoms);
}

sub _wrap_marked_lines {
	my ($text, $length, $prefix1, $prefix2) = @_;
	$prefix1 = '' unless defined $prefix1;
	$prefix2 = defined $prefix2 ? $prefix2 : $prefix1;

	my @atoms = _atoms($text);
	my @lines;
	my $prefix = $prefix1;
	my $width = $length - _visible_length($prefix);

	my @cur;
	my $visible = 0;
	my $space_at = -1;

	for my $atom (@atoms) {
		if ($atom->[1] && $visible + 1 > $width) {
			# 放不下了：本行有空格就在空格处断，否则硬断
			my @head;
			if ($space_at >= 0) {
				@head = @cur[0 .. $space_at - 1];
				@cur = $space_at + 1 <= $#cur ? @cur[$space_at + 1 .. $#cur] : ();
			} else {
				@head = @cur;
				@cur = ();
			}
			push @lines, $prefix . _join_atoms(\@head);

			$prefix = $prefix2;
			$width = $length - _visible_length($prefix);
			$visible = 0;
			$space_at = -1;
			for my $i (0 .. $#cur) {
				$visible++ if $cur[$i]->[1];
				$space_at = $i if $cur[$i]->[2];
			}
		}

		push @cur, $atom;
		$visible++ if $atom->[1];
		$space_at = $#cur if $atom->[2];
	}

	push @lines, $prefix . _join_atoms(\@cur) if @cur || !@lines;
	return @lines;
}

# print_breaking 用的入口：带标记/转义时走可见宽度折行，否则原样返回
# 「已经折好的行」，让调用方完全沿用旧路径。
sub wrap_marked {
	my ($text, $length, $prefix1, $prefix2) = @_;
	my @lines = _wrap_marked_lines($text, $length, $prefix1, $prefix2);
	return map { colorize($_) } @lines;
}

# 整段上色的便捷写法（等价于 colorize("${name}${text}${reset}")），
# 保留它是因为已有的帮助渲染按「角色」而不是「模板」调用。
sub paint {
	my ($text, $name) = @_;
	return $text if !defined $name || !defined _escape($name);
	return $text unless enabled();
	return _escape($name) . $text . $PALETTE{reset};
}

# 给调色 / 排查用：返回一份 (标记名 → 转义码) 的副本
sub palette { return %PALETTE }

1;

__END__

=head1 函数

=over 4

=item colorize(TEXT)

展开 C<${名字}>。关闭上色时把标记删掉。

=item strip(TEXT)

只删标记，用来算可见宽度或做纯文本比较。

=item paint(TEXT, ROLE)

等价于整段上色。保留是为了兼容按角色调用的老代码。

=item wrap_marked(TEXT, WIDTH, PREFIX1, PREFIX2)

按可见列数折行并展开，返回行列表。给 C<print_breaking> 用。

=item enabled()

当前是否上色。看 C<NO_COLOR> / C<CLICOLOR> / C<CLICOLOR_FORCE> / C<FINX_COLOR>。

=item tokens() / palette()

全部标记名 / 标记到转义码的映射。给 C<scripts/color_preview.pl> 与测试用。

=back

=cut
