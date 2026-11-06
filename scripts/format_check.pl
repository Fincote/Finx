#!/usr/bin/perl
# -*- mode: Perl; tab-width: 4; -*-

# Copyright (c) 2026 Sha0huaZhang <zsh@finx.sh>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
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
#
# format_check.pl - 缩进一致性检查与修正
#
# 两套规则：
#
#   Perl    tab 缩进（STYLE 原文："tabs are 4 wide"、"use tabs for indention
#           of statements"）。全仓库 2047 行 tab 对 0 行空格，这条规则是把
#           离群文件拉回既有惯例。
#   Shell   4 空格缩进。STYLE 只管 Perl；shell 此前没有规矩，这里定一条：
#           4 空格与 MacWave 一致，也与 finx-install/ 相符。
#
# 判定只看 shebang，不看扩展名 —— .in 里既有 Perl 也有 shell。
#
# 核心难点：缩进分两种，处理方式相反。
#
#   语句缩进   反映嵌套层级，按「层」换算      2 空格文件的一层 → 4 空格 / 1 tab
#   续行对齐   反映视觉列位，按「列」保留      `for x in a \` 的下一行要对齐 a
#
# 把续行也按层级换算，会把对齐拆掉；把语句也按列取整，会把嵌套压平。
# 两种都试过，都会出错，所以必须区分。
#
# 四类内容整体跳过，因为那里的缩进不是缩进：
#
#   1. heredoc 正文            可能是生成的包描述或配置文件
#   2. 跨行引号内的续行        shell 的 IFS="<换行>"、Perl 的多行字符串
#   3. POD 块                  4 空格是排版，man 页会照着渲染
#   4. __END__ / __DATA__ 之后
#
# 用法：
#   scripts/format_check.pl            检查全部受控文件，有违规退出 1
#   scripts/format_check.pl --fix      就地修正
#   scripts/format_check.pl --list     只列出会被检查的文件
#   scripts/format_check.pl FILE...    只检查指定文件

use strict;
use warnings;

# 上游 vendored 的文件：不是我们写的，改缩进等于把将来的合并变成一片冲突。
#
# update/ltmain.sh 是 1996-1999 年的 FSF libtool 脚本，2 空格缩进。它一旦有了
# shebang 就会被这里按 shell 规则检查（判定只看 shebang），于是报三千多处违规。
# 试过 `--fix`：结果是**空白合法、结构错乱** —— 例如
#
#       for arg
#       do
#     case "$arg" in
#     -c)
#         mode=compile
#     ...
#       done
#
# 循环体缩进比 for 还浅。它按「层」换算时把 case/esac 与 for/do 算成了同一层。
# 手改 4054 行 FSF 代码没有收益，所以和它的三个兄弟一起排除。
#
# 想让它参与检查，先决定「按上游原样保留」还是「当成我们自己的文件重排」。
my %EXCLUDED = map { $_ => 1 } qw(
	update/config.guess
	update/config.sub
	update/ltconfig
	update/ltmain.sh
	perlmod/Fink/Tie/IxHash.pm
	perlmod/Fink/Text/DelimMatch.pm
	perlmod/Fink/Text/ParseWords.pm
);

my $FIX  = 0;
my $LIST = 0;
my @files;

for my $arg (@ARGV) {
	if    ($arg eq '--fix')  { $FIX = 1 }
	elsif ($arg eq '--list') { $LIST = 1 }
	elsif ($arg eq '-h' || $arg eq '--help') { usage(); exit 0 }
	elsif ($arg =~ /^-/)     { die "format_check.pl: unknown option: $arg\n" }
	else                     { push @files, $arg }
}

sub usage {
	print <<'USAGE';
Usage: scripts/format_check.pl [--fix] [--list] [FILE...]

  --fix    rewrite files in place
  --list   only print which files would be checked

Rules:
  Perl   tabs
  Shell  4 spaces

Never touched: heredoc bodies, continuation lines inside an open quote,
POD blocks, and anything after __END__/__DATA__.

Not checked at all: update/config.guess, update/config.sub, update/ltconfig
(autotools vendor files) and the three CPAN-derived modules.
USAGE
}

sub tracked_files {
	my @out;
	open(my $fh, '-|', 'git', 'ls-files') or die "format_check.pl: git ls-files failed: $!\n";
	while (my $f = <$fh>) {
		chomp $f;
		next unless -f $f;
		next if $EXCLUDED{$f};
		push @out, $f if $f =~ m{\.p[lm]$} or is_script($f);
	}
	close $fh;
	return @out;
}

sub is_script {
	my $f = shift;
	open(my $fh, '<', $f) or return 0;
	my $first  = <$fh>;
	my $second = <$fh>;
	close $fh;
	my $head = ($first // '') . ($second // '');
	return $head =~ /^#!.*\b(?:perl|sh|bash|zsh|ksh)\b/ ? 1 : 0;
}

sub style_of {
	my $f = shift;
	open(my $fh, '<', $f) or return undef;
	my $first  = <$fh>;
	my $second = <$fh>;
	close $fh;
	my $head = ($first // '') . ($second // '');

	return 'perl'  if $head =~ /^#!.*\bperl\b/;
	return 'shell' if $head =~ /^#!.*\b(?:sh|bash|zsh|ksh)\b/;
	return 'perl'  if $f =~ /\.p[lm]$/;
	return undef;
}

sub heredoc_delims {
	my $line = shift;
	my @d;
	while ($line =~ /<<(-?)\s*(["']?)([A-Za-z_][A-Za-z0-9_]*)\2/g) {
		push @d, $3;
	}
	return @d;
}

# 该行结束时的引号状态。认得注释 —— pre-build-test.sh 里
# "# test whether it's a perl script" 的撇号不是引号。
sub quote_state {
	my ($line, $state) = @_;
	my $i = 0;
	my $n = length $line;
	my $at_word_start = 1;

	while ($i < $n) {
		my $c = substr($line, $i, 1);

		if ($state eq "'") {
			$state = '' if $c eq "'";
			$i++;
			next;
		}
		if ($state eq '"') {
			if ($c eq '\\') { $i += 2; next }
			$state = '' if $c eq '"';
			$i++;
			next;
		}

		if ($c eq '\\') { $i += 2; next }
		if ($c eq "'")  { $state = "'"; $i++; next }
		if ($c eq '"')  { $state = '"'; $i++; next }
		last if $c eq '#' && $at_word_start;

		$at_word_start = ($c =~ /[\s;|&()]/) ? 1 : 0;
		$i++;
	}

	return $state;
}

# 行首缩进换算成「列」（tabstop 4）
sub columns {
	my $lead = shift;
	my $col  = 0;
	for my $ch (split //, $lead) {
		if ($ch eq "\t") {
			$col += 4 - ($col % 4);
		} else {
			$col++;
		}
	}
	return $col;
}

# 扫描一遍，得到每行是否处在「续行」位置，以及该文件的空格缩进单位。
#
# 续行判定：上一条非空语句以反斜杠、管道、逻辑运算符或逗号结尾。
# 单位判定：取所有语句行空格缩进宽度的最小值（2 或 4 最常见）。
sub scan {
	my ($lines, $style) = @_;
	my @continuation;
	my @skip;
	my @heredoc;
	my $quote   = '';
	my $in_pod  = 0;
	my $in_data = 0;
	my $prev_tail = '';
	my $unit      = 4;

	for my $i (0 .. $#{$lines}) {
		my $line = $lines->[$i];
		chomp(my $chomped = $line);

		if ($style eq 'perl') {
			$in_data = 1 if $line =~ /^__(?:END|DATA)__\b/;
			if ($in_pod)  { $in_pod = 0 if $line =~ /^=cut\b/; $skip[$i] = 1; next }
			if ($line =~ /^=[a-zA-Z]/) { $in_pod = 1; $skip[$i] = 1; next }
			if ($in_data) { $skip[$i] = 1; next }
		}

		if (@heredoc) {
			shift @heredoc if $line =~ /^\s*\Q$heredoc[0]\E\s*$/;
			$skip[$i] = 1;
			next;
		}

		if ($quote ne '') {
			$quote = quote_state($line, $quote);
			$skip[$i] = 1;
			next;
		}

		$continuation[$i] = 1 if $prev_tail =~ /(?:\\|[|&,]|\|\||&&)\s*$/;

		if ($line =~ /^([ \t]+)(\S.*)$/s) {
			my $lead = $1;
			my $col  = columns($lead);
			if (   !$continuation[$i]
				&& $lead !~ /\t/
				&& $col > 0
				&& $col < $unit) {
				$unit = $col;
			}
		}

		$prev_tail = $chomped if $chomped =~ /\S/;
		push @heredoc, heredoc_delims($line);
		$quote = quote_state($line, '');
	}

	return (\@continuation, \@skip, $unit);
}

my $violations = 0;
my $changed    = 0;
my @touched;

@files = tracked_files() unless @files;

if ($LIST) {
	print "$_\n" for @files;
	exit 0;
}

for my $f (sort @files) {
	my $style = style_of($f);
	next unless defined $style;

	open(my $in, '<', $f) or do { warn "format_check.pl: cannot read $f: $!\n"; next };
	my @lines = <$in>;
	close $in;

	my ($continuation, $skip, $unit) = scan(\@lines, $style);

	my @out;
	my $file_violations = 0;

	for my $i (0 .. $#lines) {
		my $line = $lines[$i];
		if ($skip->[$i]) { push_out(\@out, $line); next }

		if ($line =~ /^([ \t]+)(\S.*)$/s) {
			my ($lead, $rest) = ($1, $2);
			my $want = _target($lead, $continuation->[$i], $unit, $style);

			if ($want ne $lead) {
				$file_violations++;
				$violations++;
				printf "%s:%d: %s\n", $f, $i + 1, _reason($lead, $unit, $style, $continuation->[$i]);
				$line = $want . $rest if $FIX;
			}
		}

		push_out(\@out, $line);
	}

	if ($FIX and $file_violations) {
		open(my $fh, '>', $f) or die "format_check.pl: cannot write $f: $!\n";
		print $fh @out;
		close $fh;
		$changed++;
		push @touched, $f;
	}
}

sub push_out {
	my ($out, $line) = @_;
	push @$out, $line;
	return;
}

if ($FIX) {
	if ($changed) {
		printf "\nfixed %d file(s):\n", $changed;
		print "  $_\n" for @touched;
		exit 0;
	}
	print "nothing to fix\n";
	exit 0;
}

if ($violations) {
	printf "\n%d indentation violation(s)\n", $violations;
	print "run 'scripts/format_check.pl --fix' to correct them\n";
	exit 1;
}

printf "indentation OK (%d files)\n", scalar(@files);
exit 0;

sub _reason {
	my ($lead, $unit, $style, $cont) = @_;
	my $what = $cont ? 'continuation alignment' : 'statement indent';
	if ($style eq 'perl') {
		return 'space before the first tab (Perl must be tab-indented)';
	}
	return 'tab in the indent (shell must use 4 spaces)' if $lead =~ /\t/;
	return "$what is not a multiple of 4";
}

# 期望的行首缩进。
#
#   Perl   只要第一个字符不是空格就算合法 —— tab 之后的空格是对齐，保留不动。
#          只有纯空格缩进需要换算成 tab。
#   Shell  语句行按层级（层数 × 4 空格），续行按列位（绝对列，向上取整到 4）。
#
# 层数的算法：tab 各算一层；空格除以为该文件探测到的缩进单位，至少一层。
# 这样 2 空格文件里的 2/4/6 空格会成为 1/2/3 层，而不是被压平成 1/1/1。
sub _target {
	my ($lead, $is_continuation, $unit, $style) = @_;

	$unit = 4 unless $unit && $unit > 0;

	if ($style eq 'perl') {
		return $lead if $lead =~ /^\t/;    # tab 开头即合法（含 tab 后的对齐空格）

		my $spaces = length $lead;
		my $level  = $spaces > 0 ? int($spaces / $unit) : 0;
		$level = 1 if $spaces > 0 && $level < 1;
		return "\t" x $level;
	}

	if ($is_continuation) {
		my $col = columns($lead);
		$col = int(($col + 3) / 4) * 4 if $col % 4;
		return " " x $col;
	}

	my ($tabs, $spaces) = (0, 0);
	for my $ch (split //, $lead) {
		if ($ch eq "\t") { $tabs++; $spaces = 0 }
		else             { $spaces++ }
	}

	my $level = $tabs;
	if ($spaces > 0) {
		my $extra = int($spaces / $unit);
		$extra = 1 if $extra < 1;
		$level += $extra;
	}

	return " " x ($level * 4);
}
