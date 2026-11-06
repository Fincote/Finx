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
# 甩出来、还以 0 退出，脚本会把打错当成成功。这三条都不会让别的测试变红，
# 所以在这里钉死。

use strict;
use Test::More tests => 12;

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

my $msg = Fink::Engine::_unknown_command_message('instal');
like($msg, qr/\Qfinx: unknown command 'instal'\E/, '第一句点名打错的命令');
like($msg, qr/did you mean 'install'\?/, '并给出最接近的命令');
like($msg, qr/finx --help/, '指向 --help');

unlike(Fink::Engine::_unknown_command_message('xyzzy'), qr/Usage:|Common commands/,
	'没有建议时也不打印帮助');

# --- 颜色：终端里看得见，重定向到日志里不能留下转义码 ---

{
	local $ENV{NO_COLOR} = 1;
	delete $ENV{FINX_COLOR};
	unlike(Fink::Engine::_unknown_command_message('instal'), qr/\033/,
		'NO_COLOR 时提示里没有转义码');
}
{
	delete local $ENV{NO_COLOR};
	local $ENV{FINX_COLOR} = 1;
	like(Fink::Engine::_unknown_command_message('instal'), qr/\033/,
		'强制上色时提示带转义码');
}

