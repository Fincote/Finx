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
# 帮助文本的配色。
#
# 三件容易写错、且都不会让别的测试变红的事，钉在这里：
#   1. 输出不是终端时不能上色（逃逸码进了日志，用户贴报错求助时就没法 grep）。
#   2. 上色不能改变对齐 —— 补空格必须按未上色的长度算。
#   3. NO_COLOR 要能压过 FINX_COLOR。

use strict;
use Test::More tests => 12;

require Fink::Help;
# 帮助的渲染在 Fink::Help（解析仍在 Fink::Services::get_options）。这里测的是
# 排版结果，所以直接按全名调用那两个函数。
sub _align_option_text { Fink::Help::align_option_text(@_) }
sub _expand_help { Fink::Help::expand_help(@_) }

my @COLOR_VARS = qw(NO_COLOR CLICOLOR CLICOLOR_FORCE FINX_COLOR);
my %saved = map { $_ => $ENV{$_} } @COLOR_VARS;
END {
	while (my ($k, $v) = each %saved) {
		if (defined $v) { $ENV{$k} = $v } else { delete $ENV{$k} }
	}
}

sub plain_env {
	delete $ENV{NO_COLOR};
	delete $ENV{CLICOLOR};
	delete $ENV{CLICOLOR_FORCE};
	delete $ENV{FINX_COLOR};
}

sub force_env {
	plain_env();
	$ENV{FINX_COLOR} = '1';
}

# 去掉转义序列，用来比对「上色前后宽度是否一致」
sub strip_ansi {
	my $s = shift;
	$s =~ s/\033\[[0-9;]*m//g;
	return $s;
}

# --- 1. 非终端默认不上色 ------------------------------------------------

{
	plain_env();
	# 测试进程的 STDOUT 是管道（Test::Harness 抓走的），所以默认这条路
	# 正好就是「被重定向」的情形。
	my $got = _align_option_text('-q, --quiet', 'be quiet', 23, 'flag');
	is($got, "  -q, --quiet           - be quiet\n",
		'no escapes when the output is not a terminal');
}

# --- 2. 强制上色后，宽度与纯文本逐字相同 ---------------------------------

{
	force_env();
	my $colored = _align_option_text('-q, --quiet', 'be quiet', 23, 'flag');
	# 缩进故意留在颜色外面（见 _paint_label 的注释），所以前面允许空白。
	like($colored, qr/^\s*\033\[36m/, 'the flag itself is cyan');
	is(strip_ansi($colored), "  -q, --quiet           - be quiet\n",
		'colouring does not move the description column');
}

# --- 3. 命令名用绿色，节标题用洋红 ---------------------------------------

{
	force_env();
	my $cmd = _align_option_text('install', 'install things', 14, 'cmd');
	like($cmd, qr/\033\[32m/, 'commands are green');

	my $help = _expand_help('', [], "Intro\n\nWidgets:\n%align{install,install things,14}\n", 23);
	like($help, qr/\033\[35mWidgets:\033\[0m/, 'a column-zero line ending in a colon is a section header');
	unlike($help, qr/\033\[35m  install/, 'indented rows are not mistaken for section headers');
}

# --- 4. 旗标的值单独上黄色 ----------------------------------------------

{
	force_env();
	my $with = _align_option_text('--trees=TREES', 'only these trees', 23, 'flag', 'TREES');
	like($with, qr/\033\[33mTREES\033\[0m/, 'the value placeholder is yellow');
	is(strip_ansi($with), "  --trees=TREES         - only these trees\n",
		'and the column does not move');
}

# --- 5. NO_COLOR 压过 FINX_COLOR ---------------------------------------

{
	force_env();
	$ENV{NO_COLOR} = '1';
	my $got = _align_option_text('-q, --quiet', 'be quiet', 23, 'flag');
	unlike($got, qr/\033\[/, 'NO_COLOR wins over FINX_COLOR');

	$ENV{NO_COLOR} = '0';
	my $back = _align_option_text('-q, --quiet', 'be quiet', 23, 'flag');
	like($back, qr/\033\[36m/, 'NO_COLOR=0 is not "set", so colour comes back');
}

# --- 6. 纯文本模式下整份帮助里一个转义都没有 ---------------------------

{
	plain_env();
	my $help = _expand_help('', [], "Intro\n\nWidgets:\n%align{install,install things,14}\n", 23);
	unlike($help, qr/\033\[/, 'no escapes anywhere when colour is off');
}

# --- 7. 纯空白行不加转义 -------------------------------------------------

{
	force_env();
	my $pad = _align_option_text('', 'just a description that wraps', 23, 'flag');
	my @lines = split /\n/, $pad;
	unlike($lines[0], qr/\033\[/, 'the blank label is not painted');
}

plain_env();
