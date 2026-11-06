# -*- mode: Perl; tab-width: 4; -*-
#
# Fink::Help - 把选项表和 helpformat 模板渲染成 --help 文本
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

package Fink::Help;

use strict;
use warnings;

use Fink::CLI qw(&word_wrap &get_term_width);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(&color_enabled &paint &paint_label &option_usage
					&align_option_text &option_help &expand_help &new_option
					&edit_distance &nearest_name
					&unknown_command_message &unknown_option_message);

=head1 NAME

Fink::Help - 渲染 `finx <command> --help`

=head1 SYNOPSIS

  use Fink::Services qw(&get_options);       # 调用方通常只碰这个

  get_options('install', [
      [ 'dry-run|n' => \$dryrun, 'Print what would be done.' ],
  ], \@_, helpformat => "%intro{[options]}\n%all{}\n");

=head1 DESCRIPTION

选项表的解析（Getopt::Long、验证、出错退出）在
C<Fink::Services::get_options>。本模块只管**把解析结果渲染成文本**：折行、
对齐、按角色上色。

之所以单独成模块：帮助的排版规则（C<%align> 的列宽、C<word_wrap> 的宽度、
缩进留在颜色外面的补空格算法）和别的东西没有关系，混在 C<Fink::Services>
里改一处要翻两千行。MacWave 的 C<lib/help.py> 是同一个位置。

=head2 helpformat 模板

C<get_options> 的 C<helpformat> 是字符串，支持这些构造：

  %opts{opt1,opt2,...}  Prints the default usage and description for the
                        given options 'opt1', 'opt2', etc.

  %all{}                Prints the default usage and description for all
                        options.

  %align{opt,desc}      Prints the option 'opt' and its description 'desc',
                        aligned with other options.

  %align{opt,desc,optspace}
                        Prints the option 'opt' and its description 'desc',
                        aligned such that the option part takes up a width
                        of optspace characters.

  %intro{ex,...}        Print a help introduction, with 'ex' as a very short
                        generic example of calling this command, such as:
                        '[options] [packages]'. With multiple examples, will
                        print one per line.

  %%                    Print a literal percent character.

Percent can also be used to escape comma and curly brackets inside an
expansion.

模板里不出现 C<${name}> 颜色标记：颜色在这里是**直接产出转义码**的（见
C<paint>），所以文本本身保持纯文本，任何按字面处理的工具都不会被转义码
干扰。开关由 C<Fink::Color::enabled> 统一决定。

=cut

# 颜色的定义与开关都在 Fink::Color；这里只是两个薄包装，因为帮助渲染是按
# 「角色」（section/prog/flag/value）取色的，而不是按名字。

=item color_enabled

  my $bool = color_enabled();

与 C<Fink::Color::enabled> 相同。单独导出是因为模板处理要用它决定是否
把顶格的节标题刷成 C<section> 色。

=cut

sub color_enabled {
	require Fink::Color;
	return Fink::Color::enabled();
}

=item paint

  my $text = paint($text, $role);

按角色整段上色。C<$role> 是 C<%PALETTE> 里的语义别名（C<section>、
C<prog>、C<flag>、C<value>、C<bold>）。上色关闭时原样返回。

=cut

sub paint {
	my ($text, $role) = @_;
	require Fink::Color;
	return Fink::Color::paint($text, $role);
}

# 程序标记（🧩）。和 paint 一样是薄包装，免得每个调用点自己 require。
sub _mark {
	require Fink::Color;
	return Fink::Color::prog_mark();
}

=item paint_label

  my $text = paint_label($text, $role, $value);

给「标签 + 值」的文本上色：标签用 C<$role>，末尾那个值占位符（如
C<--trees=TREES> 里的 C<TREES>）用 C<value> 色。

缩进故意留在颜色外面 —— 转义码把空格包住时，某些终端在复制粘贴时会带出
多余的空格。

=cut

sub paint_label {
	my ($text, $role, $value) = @_;
	return $text if $text =~ /^\s*$/;
	return $text if !color_enabled();

	my ($indent, $body) = $text =~ /^(\s*)(.*)$/;
	if (defined $value && length $value) {
		my $quoted = quotemeta $value;
		if ($body =~ /^(.*?)([=\s])($quoted)$/) {
			return $indent . paint($1, $role) . $2 . paint($3, 'value');
		}
	}
	return $indent . paint($body, $role);
}

=item option_usage

  my $text = option_usage($optitem);

把 Getopt 的选项规格写成给人看的形式：C<-f, --full=VALUE>。短选项带空格
接值，长选项用等号。

=cut

sub option_usage {
	my $opt = shift;

	# Try each way to specify option (eg: -f, --full)
	my @alts = sort { length($a) <=> length($b) } @{$opt->{names}};
	foreach my $alt (@alts) {
		if (length($alt) == 1) {
			$alt = "-$alt";
			$alt .= " $opt->{value}" if defined $opt->{value};
		} else {
			$alt = "--$alt";
			$alt .= "=$opt->{value}" if defined $opt->{value};
		}
	}
	return join ', ', @alts;
}

=item align_option_text

  my $text = align_option_text($usage, $desc, $optlen, $role, $value);

把一行的「用法」和「描述」并排成两列，描述按终端宽度折行。

C<$role> 决定标签用什么颜色（C<cmd> 或 C<flag>），C<$value> 是旗标值的
占位符名。

补空格必须按**未上色**的长度算 —— 逃逸码会让 C<length()> 长出五六个字符，
于是列就对不齐了。

=cut

sub align_option_text {
	my ($opttxt, $desctxt, $optlen, $role, $value) = @_;
	my $ret = "";

	# Word wrap things
	my $desclen; # Ensure there's a reasonable size
	for my $width (get_term_width(), 80) {
		$desclen = $width - $optlen - 3;
		last if $desclen > 5;
	}

	my @optlines = word_wrap $opttxt, $optlen, '  ', '    ';
	my @desclines = map { word_wrap $_, $desclen }
		split /\n/, $desctxt; # Respect newlines

	# Add 'em to the message by pairs
	my $first = 1;
	while (1) {
		my $optpart = shift @optlines;
		my $descpart = shift @desclines;
		last unless defined $optpart || defined $descpart;
		$descpart = '' unless defined $descpart;

		my $midpart = $first ? ' - ' : '   ';
		$first = 0 if $first;

		if (!defined $optpart) {
			$ret .= (' ' x $optlen) . $midpart . $descpart . "\n";
			next;
		}

		my $pad = $optlen - length($optpart);
		$pad = 0 if $pad < 0;
		$ret .= paint_label($optpart, $role, $value) . (' ' x $pad)
			. $midpart . $descpart . "\n";
	}

	return $ret;
}

=item option_help

  my $text = option_help($optitem, $optlen);

一个选项的完整帮助，可能多行。带 C<!> 修饰的选项（如 C<use-binary-dist!>）
会额外生成一个 C<--no-...> 条目。

=cut

sub option_help {
	my ($opt, $optlen) = @_;
	my @realopts;
	$DB::single = 1 if grep { $_ eq 'use-binary-dist' } @{$opt->{names}};
	if ($opt->{modifiers} =~ /!/) {
		require Storable;
		my $negopt = Storable::dclone($opt);
		$negopt->{names} = [
			map { length($_) > 1 ? "no-$_" : () } @{$opt->{names}}
		];
		$negopt->{help} = 'Opposite of --'.$opt->{names}->[0];
		@realopts = ($opt, $negopt);
	} else {
		@realopts = $opt;
	}

	my $text = '';
	for my $ropt (@realopts) {
		my $usage = option_usage($ropt);
		$text .= align_option_text($usage, $ropt->{help}, $optlen,
			'flag', $ropt->{value});
	}
	return $text;
}

=item new_option

  my $opthash = new_option(@optarray);

把一个选项条目（C<['spec' => \$var, '帮助文字', 'VALUE']>）变成内部哈希：
C<spec/names/modifiers/dest/help/value>。

=cut

sub new_option {
	my $opthash;
	@$opthash{qw(spec dest help value)} = @_;
	$opthash->{spec} =~ /^([\w-]+(\|[\w-]+)*)(.*)$/
		or die "Bad option specification: $opthash->{spec}\n";
	$opthash->{names} = [ split /\|/, $1 ];
	$opthash->{modifiers} = $3;
	return $opthash;
}

=item expand_help

  my $text = expand_help($command, $optionlist, $helpformat, $optlen);

展开 C<helpformat> 模板，返回整块帮助文本。调用方负责打印（
C<Fink::Services::get_options> 用裸 C<print>，不经过 C<print_breaking>）。

最后一步把顶格、以冒号结尾的行（C<Common commands:>）刷成 C<section> 色：
这些行是模板里的普通文本，没有别的地方可以挂钩。限定顶格，所以缩进的描述
行不会被误伤。

=cut

sub expand_help {
	my ($command, $options, $helpformat, $optlen) = @_;

	# Option table
	my %opts;
	foreach my $opt (@$options) {
		my @names = @{$opt->{names}};
		@opts{@names} = ($opt) x scalar(@names);
	}

	# Expansion table
	my %exp = (
		all => sub {
			"Options:\n" . join '', map { option_help($_, $optlen) }
				@$options;
		},
		opts => sub {
			if (my @missing_opts = grep {!exists $opts{$_}} @_) {
				die "Options (@missing_opts) from \%opts{@_} not defined in option list ("
					. (join ' ', keys %opts) . ")\n";
			}
			chomp (my $ret = join '', map { option_help($_, $optlen) }
				@opts{@_} );
			$ret;
		},
		align	=> sub {
			# %align 自带第三参数 optspace（Config.pm 传 $comlen），没给才用默认宽度。
			# 所以不能写成 align_option_text(@_, $optlen, 'cmd')：那会多顶一位，
			# 把全局 optwidth 当成 optspace、把 'cmd' 当成值占位符。
			my ($otxt, $dtxt, $ospace) = @_;
			$ospace = $optlen unless defined $ospace;
			chomp (my $ret = align_option_text($otxt, $dtxt, $ospace, 'cmd'));
			$ret
		},
		intro	=> sub {
			my $first = shift;
			require Fink::FinkVersion;
			my $prog = 'finx';
			my $usage = paint('Usage:', 'section') . ' '
				. paint($prog, 'prog') . $command;
			paint('Finx ' . Fink::FinkVersion::fink_version(), 'bold') . "\n\n" .
				$usage . " $first\n" .
				join '', map { '       ' . paint($prog, 'prog')
					. $command . " $_\n" } @_;
		},
	);

	# Do the format
	$helpformat =~ s"(?<!\%)((?:\%\%)*)\%(\w+)\{(|.*?[^%])\}"
		return $& unless exists $exp{$2};
		my @args = map { s/(?<!\%)((?:\%\%)*)%([{},])/$1$2/g; $_ }
			split /(?<!%),/, $3;
		$1 . &{$exp{$2}}(@args);
	"ge;
# " <-- preceding s using " as delim confuses emacs syntax-highlight
	$helpformat =~ s/%%/%/g;

	# 节标题统一上色。放在最后一步：它们是模板里的普通文本（`Common commands:`
	# 这类顶格、以冒号结尾的行），没有别的地方可以挂钩。限定顶格，所以缩进的
	# 描述行不会被误伤。
	if (color_enabled()) {
		$helpformat =~ s{^(\S[^\n:]*):$}{paint("$1:", 'section')}gme;
	}

	return $helpformat;
}

# ---------------------------------------------------------------------------
# 打错命令 / 打错旗标时的提示
# ---------------------------------------------------------------------------
#
# 形状照 MacWave 的 lib/help.py（print_error_help）：先回显**用户真实输入的
# 那一行**，用 ^ 指住出错的那个词，再给改法。两件事与「猜不猜得到」无关：
#
#   1. 回显命令行。猜得到时它让人看清错的是哪个词；猜不到时它是唯一的定位信息。
#   2. **绝不打印整篇帮助**。那几十行会在终端里滚过一整屏，把真正有用的两行
#      （错在哪个词、该敲什么）推到看不见的地方 —— 想知道全部命令的人自己会敲
#      `finx -h`。所以这里只留一条指向它的提示。
#
# 颜色与普通消息同一套：出错的那个词、脱字符、Error 行用 error，改法里的正确
# 写法用 ok，指路用的命令名用 cmd。

# 编辑距离，两行滚动数组。输入都是命令名或旗标名，长度不超过二十几个字符。
sub edit_distance {
	my ($a, $b) = @_;
	return length($a) > length($b)
		? edit_distance($b, $a) : _edit_distance_into($a, $b);
}

sub _edit_distance_into {
	my ($a, $b) = @_;
	# $a 是短的那个，只为了少分配一行
	my @prev = (0 .. length $b);
	foreach my $i (1 .. length $a) {
		my @cur = ($i);
		foreach my $j (1 .. length $b) {
			my $cost = substr($a, $i - 1, 1) eq substr($b, $j - 1, 1) ? 0 : 1;
			my $v = $prev[$j] + 1;
			$v = $cur[$j - 1] + 1 if $cur[$j - 1] + 1 < $v;
			$v = $prev[$j - 1] + $cost if $prev[$j - 1] + $cost < $v;
			$cur[$j] = $v;
		}
		@prev = @cur;
	}
	return $prev[length $b];
}

# 从候选里挑一个最像的。只在两种情况下认：前缀关系（instal / install、
# --connect-time / --connect-timeout），或者编辑距离不超过 2（instll / install）。
# 差得远就不猜 —— 猜错比不猜更糟，用户照着改还会再撞一次。
sub nearest_name {
	my ($word, @candidates) = @_;
	return undef if !defined $word || length($word) < 3;

	my ($best, $best_score);
	foreach my $name (@candidates) {
		my $score;
		if (index($name, $word) == 0 || index($word, $name) == 0) {
			$score = 0;
		} elsif (abs(length($name) - length($word)) <= 2) {
			$score = edit_distance($word, $name);
			next if $score > 2;
		} else {
			next;
		}
		if (!defined $best_score
			|| $score < $best_score
			|| ($score == $best_score && length($name) < length($best))) {
			($best, $best_score) = ($name, $score);
		}
	}
	return $best;
}

# 回显命令行 + 脱字符行。
#
#   $indent     行首缩进
#   \@words     要回显的词
#   $bad        出错的下标
#   $span       标红的长度（只标旗标名时用，值部分留着原样）；undef = 整个词
#
# 返回两行（都以换行结尾）。缩进与脱字符都按**未上色**的长度算 —— 逃逸码零宽
# 但计入 length，混进来 ^ 就会错位。
sub _replay_and_caret {
	my ($indent, $words, $bad, $span) = @_;
	my @shown;
	foreach my $i (0 .. $#$words) {
		my $word = $words->[$i];
		if ($i != $bad) {
			push @shown, $word;
			next;
		}
		if (defined $span) {
			my ($name, $rest) = $word =~ /^([^=]*)(=.*)?$/;
			push @shown, paint($name, 'error') . (defined $rest ? $rest : '');
		} else {
			push @shown, paint($word, 'error');
		}
	}

	my $before = $indent . join(' ', @{$words}[0 .. $bad - 1]);
	$before .= ' ' if $bad > 0;
	my $width = defined $span ? $span : length($words->[$bad]);

	return $indent . join(' ', @shown) . "\n"
		. paint((' ' x length($before)) . ('^' x $width), 'error') . "\n";
}

=item unknown_command_message

  my $text = unknown_command_message(\@argv, $cmd, $near);

打错子命令时的整段提示。C<\@argv> 是用户真实输入（不含程序名），C<$cmd> 是
被当成命令的那个词，C<$near> 是猜出来的正确命令（猜不到传 undef）。

=cut

sub unknown_command_message {
	my ($argv, $cmd, $near) = @_;
	my @words = @{ $argv || [$cmd] };
	$cmd = '' unless defined $cmd;

	# 指住用户当成命令的那个词。找不到（比如 argv 与 $cmd 对不上）就退回到
	# 第一个不以 - 开头的词，至少还能定位。
	my $bad;
	foreach my $i (0 .. $#words) {
		if ($words[$i] eq $cmd) { $bad = $i; last }
	}
	if (!defined $bad) {
		foreach my $i (0 .. $#words) {
			if ($words[$i] !~ /^-/) { $bad = $i; last }
		}
	}

	my $mark = _mark();
	my $text = paint("$mark Error: Unknown command or argument.", 'error') . "\n\n";
	$text .= _replay_and_caret('   ', \@words, $bad) . "\n" if defined $bad;

	if (defined $near && length $near) {
		my @fixed = @words;
		$fixed[$bad] = $near if defined $bad;
		my $shown = join ' ', map {
			$_ eq $near ? paint($_, 'ok') : $_
		} @fixed;
		$text .= paint("$mark Did you mean:", 'bold') . " $shown\n\n";
		$text .= '   ' . paint($cmd, 'warn') . ' is not a command. '
			. 'The one you want is ' . paint($near, 'ok') . ".\n\n";
	}
	$text .= '   For the full list: ' . paint('finx -h', 'cmd') . "\n";
	return $text;
}

=item unknown_option_message

  my $text = unknown_option_message($command, \@argv, $token, $near);

参数打错时的整段提示。C<$command> 是当前子命令（全局选项时为空串），
C<\@argv> 是用户真实输入（不含程序名），C<$token> 出事的那一整段
（如 C<--connect-time=12s>），C<$near> 是猜出来的旗标（猜不到传 undef）。

只给旗标名上色与打 ^，值部分（C<=12s>）留着原样 —— 让人一眼看出错的是名字，
不是值。
=cut

sub unknown_option_message {
	my ($command, $argv, $token, $near) = @_;
	my @words = @{ $argv || [] };
	my $cmd = defined $command ? $command : '';
	$cmd =~ s/^\s+//;

	my $bad;
	foreach my $i (0 .. $#words) {
		if ($words[$i] eq $token) { $bad = $i; last }
	}
	my ($span) = $token =~ /^([^=]*)/;
	$span = length $token unless defined $span && length $span;

	my $for = length $cmd ? "for `finx $cmd`" : 'for `finx`';
	my $mark = _mark();
	my $text = paint("$mark Error: illegal option $span $for", 'error')
		. "\n\n";
	$text .= _replay_and_caret('   ', \@words, $bad, length $span)
		. "\n" if defined $bad;

	if (defined $near && length $near) {
		$text .= paint("$mark Next:", 'bold')
			. ' Did you mean ' . paint($near, 'ok') . "?\n\n";
	}
	$text .= paint("$mark ", 'bold')
		. paint(length $cmd ? "finx $cmd --help" : 'finx --help', 'cmd')
		. ' lists the flags ' . (length $cmd ? 'this command' : 'finx')
		. " accepts\n";
	return $text;
}

1;
