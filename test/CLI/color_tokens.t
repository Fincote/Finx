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
# 颜色标记（${name}）的展开、关闭与折行。
#
# 三件容易写错、且都不会让别的测试变红的事，钉在这里：
#   1. 关闭上色时必须把标记删干净 —— 留下逃逸码就没法 grep 日志。
#   2. 标记是零宽的，折行要按可见列数算，否则长消息会窄一截。
#   3. 未知标记不能把 ${...} 原样漏给用户。

use strict;
use Test::More tests => 19;

require Fink::Color;
require Fink::CLI;

my @VARS = qw(NO_COLOR CLICOLOR CLICOLOR_FORCE FINX_COLOR);
my %saved = map { $_ => $ENV{$_} } @VARS;
END {
	while (my ($k, $v) = each %saved) {
		if (defined $v) { $ENV{$k} = $v } else { delete $ENV{$k} }
	}
}

sub clear_env { delete @ENV{@VARS} }
sub force_on  { clear_env(); $ENV{FINX_COLOR} = '1' }
sub force_off { clear_env(); $ENV{NO_COLOR} = '1' }

my $ESC = "\033";

# --- 1. 展开与关闭 --------------------------------------------------------

{
	force_on();
	is(Fink::Color::colorize('${yellow}hi${reset}'),
		$ESC . '[33mhi' . $ESC . '[0m', 'a known token expands');

	force_on();
	is(Fink::Color::colorize('%{yellow}hi%{reset}'),
		$ESC . '[33mhi' . $ESC . '[0m',
		'the %{name} form needs no escaping inside double quotes');

	force_off();
	is(Fink::Color::colorize('${yellow}hi${reset}'), 'hi',
		'tokens are removed, not escaped, when colour is off');

	force_on();
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, $_[0] };
	is(Fink::Color::colorize('${nosuchtoken}x'), 'x',
		'an unknown token is dropped rather than printed to the user');
	like($warnings[0], qr/unknown colour token \$\{nosuchtoken\}/,
		'and it says so once, on stderr');
}

# --- 2. strip ------------------------------------------------------------

{
	force_on();
	is(Fink::Color::strip('${red}a${reset}b'), 'ab', 'strip removes tokens');
	is(Fink::Color::strip($ESC . '[31ma' . $ESC . '[0m'), 'a',
		'strip also removes escapes that are already there');
}

# --- 3. paint 仍然可用（帮助渲染按角色调用） -----------------------------

{
	force_on();
	is(Fink::Color::paint('x', 'cmd'), $ESC . '[32mx' . $ESC . '[0m',
		'paint colours a whole string by role');
	is(Fink::Color::paint('x', 'nosuchrole'), 'x',
		'paint leaves unknown roles alone');
}

# --- 4. 折行按可见列数 ---------------------------------------------------

{
	force_on();
	my $text = '${bold}' . ('word ' x 20) . '${reset}';
	my @lines = Fink::Color::wrap_marked($text, 30, '', '    ');
	ok(@lines > 1, 'a long marked string wraps');

	my $max = 0;
	foreach my $line (@lines) {
		my $visible = length Fink::Color::strip($line);
		$max = $visible if $visible > $max;
	}
	cmp_ok($max, '<=', 30, 'no line exceeds the width, counted in visible columns');
	like($lines[1], qr/^\s{4}/, 'the continuation prefix is applied');
	like($lines[0], qr/^\Q$ESC\E\[1m/, 'the colour survives the wrap');
}

# --- 5. 没有标记时 print_breaking 的行为不变 -----------------------------

{
	force_on();
	my @lines = Fink::CLI::word_wrap('alpha beta gamma', 8);
	is_deeply(\@lines, ['alpha', 'beta', 'gamma'],
		'word_wrap itself is untouched for plain text');
	unlike($lines[0], qr/\Q$ESC\E/, 'and produces no escapes');
}

# --- 6. 调色板 -----------------------------------------------------------

{
	my %palette = Fink::Color::palette();
	ok($palette{reset}, 'the palette has a reset entry');
	my %tokens = map { $_ => 1 } Fink::Color::tokens();
	ok($tokens{yellow} && $tokens{cmd} && $tokens{error},
		'both basic and semantic names are registered');
	force_off();
	is(Fink::Color::enabled(), 0, 'NO_COLOR turns colour off');
	clear_env();
	$ENV{FINX_COLOR} = '1';
	$ENV{NO_COLOR} = '1';
	is(Fink::Color::enabled(), 0, 'NO_COLOR beats FINX_COLOR');
}

clear_env();
