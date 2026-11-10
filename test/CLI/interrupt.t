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
# Ctrl+C 的处理。
#
# 默认的 SIGINT 会让 perl 当场结束，屏幕上什么都不留 —— 用户看到的是编译到
# 一半的目录和一个没有解释的提示符，与「命令跑完了」长得一样。Shell 脚本能靠
# $? 分辨（130），人不能。所以统一成：一句「已取消」+ 退出码 130，与 MacWave
# 的 wave.py 一致。
#
# 钉住四件事：
#   1. 句柄只 die 一个固定字符串，别的地方能认出来
#   2. 认出来的地方打一句带程序标记的「已取消」
#   3. 退出码是 130（128 + SIGINT）
#   4. $INTERRUPT 必须仍含 "User interrupt" —— Fink::Scanpackages 靠它判断
#      「这不是真的错误，别降级成警告」

use strict;
use Test::More tests => 8;

require Fink::CLI;

# --- 句柄 ---------------------------------------------------------------

{
	my $old = $SIG{INT};
	Fink::CLI::install_interrupt_handler();
	eval {
		kill 'INT', $$;         # 发给自己的这个信号会被句柄接住
	};
	$SIG{INT} = $old;
	like($@, qr/^User interrupt\./,
		'句柄 die 的是一条固定消息，不带文件名与行号');
	ok(Fink::CLI::interrupted($@), 'interrupted() 认得出来');
}

# --- 别的错误不算中断 ---------------------------------------------------

ok(!Fink::CLI::interrupted("no package found for 'foo'\n"),
	'普通错误不算中断');
ok(!Fink::CLI::interrupted(''), '空错误不算中断');
ok(!Fink::CLI::interrupted(undef), 'undef 也不算');

# --- 提示与退出码 -------------------------------------------------------

{
	my $err = '';
	{
		local *STDERR;
		open STDERR, '>', \$err or die $!;
		is(Fink::CLI::report_interrupt(), 130,
			'退出码 130（128 + SIGINT）');
	}
	is($err, "Operation cancelled by user.\n",
		'只有这一句，没有前缀也没有转义码');
}

# --- 与 Scanpackages 的约定 --------------------------------------------

like($Fink::CLI::INTERRUPT, qr/User interrupt/,
	'$INTERRUPT 仍含 "User interrupt"（Scanpackages 靠它区分中断与错误）');
