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
# 打错子命令。
#
# 原来的行为是 `exit &execute("finx --help")`：一句提示都没有、整份帮助
# 甩出来、还以 0 退出，脚本会把打错当成成功。后来又变成只有两行、没有定位。
# 现在的形状照 MacWave 的 print_error_help：回显用户真实输入的那一行、用 ^
# 指住出错的那个词、给出改法，并且**任何情况下都不打印整篇帮助**。
#
# 这几条都不会让别的测试变红，所以在这里钉死：
#   1. 猜得到时给完整改法（其余参数原样保留）
#   2. 猜不到也要指出错在哪个词
#   3. 关闭上色时不留转义码，强制上色时有

use strict;
use Test::More tests => 19;

require Fink::Engine;

# --- 该给建议的 ---

is(Fink::Engine::_nearest_command('instal'), 'install',
	'前缀少一个字符');
is(Fink::Engine::_nearest_command('isntall'), 'install',
	'两个字母对调');
is(Fink::Engine::_nearest_command('remve'), 'remove',
	'少一个字母');
is(Fink::Engine::_nearest_command('purgee'), 'purge',
	'多一个字母');

# --- 不该乱猜的 ---

is(Fink::Engine::_nearest_command('xyzzy'), undef,
	'差得远就不猜');
is(Fink::Engine::_nearest_command('in'), undef,
	'太短，不值得猜');

# --- 提示本身 ---

my $msg = Fink::Engine::_unknown_command_message('instll', [qw(instll jq)]);
like($msg, qr/Error: Unknown command or argument\./,
	'第一句说清是什么错');
like($msg, qr/^   finx instll jq$/m,
	'回显用户真实输入，一字不改');
like($msg, qr/^        \^{6}$/m,
	'脱字符正好在出错的那个词下面（"instll" 六个字母）');
like($msg, qr/Did you mean: finx install jq/,
	'改法里保留其余参数');
like($msg, qr/instll is not a command\. The one you want is install\./,
	'一句话说清错在哪、该敲什么');
like($msg, qr/finx -h/, '指向 -h');

my $vague = Fink::Engine::_unknown_command_message('xyzzy', [qw(xyzzy)]);
unlike($vague, qr/Did you mean/, '猜不到就不给改法');
like($vague, qr/^   finx xyzzy$/m, '猜不到也要回显');
like($vague, qr/^        \^{5}$/m, '猜不到也要指出是哪个词');

foreach my $m ($msg, $vague) {
	unlike($m, qr/Usage:|Common commands/, '任何情况下都不打印整篇帮助');
}

# --- 颜色：终端里看得见，重定向到日志里不能留下转义码 ---

{
	local $ENV{NO_COLOR} = 1;
	delete $ENV{FINX_COLOR};
	unlike(Fink::Engine::_unknown_command_message('instll', [qw(instll)]), qr/\033/,
		'NO_COLOR 时提示里没有转义码');
}
{
	delete local $ENV{NO_COLOR};
	local $ENV{FINX_COLOR} = 1;
	like(Fink::Engine::_unknown_command_message('instll', [qw(instll)]), qr/\033/,
		'强制上色时提示带转义码');
}
