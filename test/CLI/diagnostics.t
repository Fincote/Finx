#!/usr/bin/perl -w
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
# 诊断消息的统一外观。
#
# 全项目有三十多处 "ERROR: …" / "WARNING: …"，散在六个模块里。要求每个调用点
# 自己记得上色和加标记，迟早会漏 —— 而漏掉的往往是最少走到的那条。所以统一
# 在 print_breaking 里做（Fink::Color::style_diagnostic）。
#
# 钉住四件事：
#   1. ERROR 是红的、WARNING 是黄的，段首有程序标记
#   2. 多段消息每段都带标记（只第一段有的话，下面几段像别人的输出）
#   3. 作者自己上过色的消息原样不动（否则会把 ${reset} 之后的文字染黑）
#   4. 关闭上色时标记还在、转义码没有 —— 标记是信息，不是装饰

use strict;
use Test::More tests => 12;

require Fink::Color;
require Fink::CLI;

my $MARK = Fink::Color::prog_mark();

my @VARS = qw(NO_COLOR CLICOLOR CLICOLOR_FORCE FINX_COLOR);
my %saved = map { $_ => $ENV{$_} } @VARS;
END {
	while (my ($k, $v) = each %saved) {
		if (defined $v) { $ENV{$k} = $v } else { delete $ENV{$k} }
	}
}
sub clear_env { delete @ENV{@VARS} }
sub force_on { clear_env(); $ENV{FINX_COLOR} = 1 }
sub force_off { clear_env(); $ENV{NO_COLOR} = 1 }

# --- 标记本身 -----------------------------------------------------------

isnt(index($MARK, "\xF0\x9F\xA7\xA9"), -1,
	'程序标记是 UTF-8 字节串，不是宽字符（否则 print 会警告 Wide character）');

# --- 识别与上色 ---------------------------------------------------------

{
	force_on();
	my $got = Fink::Color::colorize(
		Fink::Color::style_diagnostic('ERROR: cannot continue'));
	is($got, "\033[1;31m${MARK} ERROR: cannot continue\033[0m",
		'ERROR: 上 error 红，并在段首加标记');
}
{
	force_on();
	my $got = Fink::Color::colorize(
		Fink::Color::style_diagnostic('WARNING: check this'));
	is($got, "\033[33m${MARK} WARNING: check this\033[0m",
		'WARNING: 上 warn 黄');
}
{
	force_on();
	my $got = Fink::Color::colorize(Fink::Color::style_diagnostic('Failed: boom'));
	like($got, qr/^\033\[1;31m\Q$MARK\E Failed: boom/, 'Failed: 也算诊断消息');
}

# --- 不该碰的 -----------------------------------------------------------

{
	force_on();
	is(Fink::Color::style_diagnostic('Installing ncdu'), 'Installing ncdu',
		'普通输出原样返回');
	my $coloured = '${error}ERROR: already coloured${reset}';
	is(Fink::Color::style_diagnostic($coloured), $coloured,
		'作者已经写过标记的消息不动（否则会打乱他排的颜色）');
}

# --- 多段 ---------------------------------------------------------------

{
	force_on();
	my $got = Fink::Color::style_diagnostic("WARNING: one\n\nERROR: two\n");
	is(scalar(my @m = $got =~ /\Q$MARK\E/g), 2, '每段都有标记');
	like($got, qr/ERROR: two/, '第二段保留原意');
	unlike($got, qr/\n\033\[0m$/, '结尾的换行在 reset 之后，不把颜色漏给下一条输出');
}

# --- 关闭上色 -----------------------------------------------------------

{
	force_off();
	my $got = Fink::Color::colorize(
		Fink::Color::style_diagnostic('ERROR: no colour'));
	is($got, "$MARK ERROR: no colour", '关闭上色：标记保留，转义码为零');
}

# --- 经 print_breaking 的最终形态 --------------------------------------

{
	force_off();
	my $out = '';
	{
		local *STDOUT;
		open STDOUT, '>', \$out or die $!;
		Fink::CLI::print_breaking('ERROR: apt-get is missing. Install it, then try again.');
	}
	like($out, qr/^\Q$MARK\E ERROR: apt-get is missing\./,
		'print_breaking 自动认出诊断消息');
	unlike($out, qr/\033/, '关闭上色时没有转义码');
}
