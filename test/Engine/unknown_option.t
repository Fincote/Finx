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
# 打错旗标时的提示，形状与打错命令时一致（都在 Fink::Help 里）。
#
# 以前 Getopt::Long 只往 STDERR 甩一句 "Unknown option: xxx"，既没有命令
# 上下文，也不说该敲什么。现在：回显用户真实输入、只给旗标名上色与打 ^
# （值部分留着）、猜得到就给出正确写法。
#
# 钉住四件事：
#   1. `^` 只盖住旗标名，不盖住 =12s
#   2. 猜不到时不留 "Next:"，但仍指出去哪儿看
#   3. 全局选项（没有子命令）也说得对
#   4. 关闭上色时不留转义码

use strict;
use Test::More tests => 16;

require Fink::Help;

my @argv = qw(finx install jq --connect-time=12s);
my $msg = Fink::Help::unknown_option_message(
	'install', \@argv, '--connect-time=12s', '--connect-timeout');

like($msg, qr/illegal option --connect-time for `finx install`/,
	'第一句点名是哪个旗标、哪条命令');
like($msg, qr/^   finx install jq --connect-time=12s$/m,
	'回显用户真实输入');
like($msg, qr/^ {19}\^{14}$/m,
	'脱字符只盖住旗标名（14 个字符），不含 =12s');
like($msg, qr/Did you mean --connect-timeout\?/, '给出正确写法');
like($msg, qr/finx install --help/, '指到该命令的帮助');

# 猜不到：没有 Next，但要说清去哪儿看
my $vague = Fink::Help::unknown_option_message(
	'mirror', [qw(finx mirror --zzz)], '--zzz', undef);
unlike($vague, qr/Next:/, '猜不到就不给改法');
like($vague, qr/finx mirror --help/, '猜不到也要指出帮助在哪');

# 全局选项：没有子命令
my $global = Fink::Help::unknown_option_message(
	'', [qw(finx --quite mirror)], '--quite', '--quiet');
like($global, qr/illegal option --quite for `finx`/, '全局层不编一个子命令');
like($global, qr/^ {8}\^{7}$/m, '全局层的脱字符也在词下面');
like($global, qr/finx --help/, '指向全局帮助');

# 建议算法本身
is(Fink::Help::nearest_name('--connect-time',
		'--connect-timeout', '--content-time'), '--connect-timeout',
	'前缀关系算最接近');
is(Fink::Help::nearest_name('--jsons', '--json', '--raw'), '--json',
	'多一个字母也能认');
is(Fink::Help::nearest_name('--zzz', '--json', '--raw'), undef,
	'差得远就不猜');
is(Fink::Help::nearest_name('-z', '-h', '-q'), undef,
	'单字母不猜（否则 -z 会被猜成 -h）');

{
	local $ENV{NO_COLOR} = 1;
	delete $ENV{FINX_COLOR};
	unlike(Fink::Help::unknown_option_message('install', \@argv,
			'--connect-time=12s', '--connect-timeout'), qr/\033/,
		'NO_COLOR 时提示里没有转义码');
}
{
	delete local $ENV{NO_COLOR};
	local $ENV{FINX_COLOR} = 1;
	like(Fink::Help::unknown_option_message('install', \@argv,
			'--connect-time=12s', '--connect-timeout'), qr/\033/,
		'强制上色时提示带转义码');
}
