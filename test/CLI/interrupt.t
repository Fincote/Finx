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
#   2. 认出来的地方打一句「已取消」
#   3. 退出码是 130（128 + SIGINT）
#   4. $INTERRUPT 必须仍含 "User interrupt" —— Fink::Scanpackages 靠它判断
#      「这不是真的错误，别降级成警告」
#   5. 子进程被 ^C 杀掉时也要报成取消，而不是「编译失败」
#   6. ignore_INT 那一段（dpkg）要把 ^C 推迟到命令结束，不能丢

use strict;
use Test::More tests => 16;

require Fink::CLI;
require Fink::Services;

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

# --- execute：子进程被 ^C 杀掉 -----------------------------------------
#
# 用「自己给自己发 SIGINT」造出同样的退出状态，不必真的去信号别人：
#   sh -c 'kill -INT $$' → 子进程被信号 2 杀死，$? == 2
#   sh -c 'exit 130'     → 有的 shell 会按 128+2 退出
# 两种都要认成取消。不然 ^C 会被报成「编译失败」，还附带两屏「请提 issue」。

{
	my $quiet = '';
	{
		local *STDOUT;
		open STDOUT, '>', \$quiet or die $!;
		eval { Fink::Services::execute('sh -c "kill -INT \$\$"') };
	}
	ok(Fink::CLI::interrupted($@), '子进程被信号 2 杀掉 → 认成取消');
}

{
	my $quiet = '';
	{
		local *STDOUT;
		open STDOUT, '>', \$quiet or die $!;
		eval { Fink::Services::execute('sh -c "exit 130"') };
	}
	ok(Fink::CLI::interrupted($@), '子进程自己按 128+2 退出 → 也认成取消');
}

{
	my $quiet = '';
	my ($rc, $err);
	{
		local *STDOUT;
		open STDOUT, '>', \$quiet or die $!;
		eval { $rc = Fink::Services::execute('true') };
		$err = $@;
	}
	is($rc, 0, '成功的命令照旧返回 0，不会误判成取消');
	ok(!Fink::CLI::interrupted($err), '而且没有抛异常');
}

# 位移之后的「退出码 2」与「被信号 2 杀掉」长得一模一样，两者不能混为一谈：
# `exit 2` 满地都是，把它报成「用户取消」会让真失败被当成用户按了 ^C。
{
	my $quiet = '';
	my ($rc, $err);
	{
		local *STDOUT;
		open STDOUT, '>', \$quiet or die $!;
		eval { $rc = Fink::Services::execute('sh -c "exit 2"') };
		$err = $@;
	}
	is($rc, 2, '退出码 2 原样返回');
	ok(!Fink::CLI::interrupted($err), '不会当成 ^C');
}

# --- ignore_INT：推迟，而不是丢弃 --------------------------------------
#
# 让一个助手进程稍后给我们发 SIGINT，主流程在 ignore_INT 里等一条慢命令。
# 期望：命令跑完（子进程没被杀），然后才抛中断。

{
	my $quiet = '';
	my ($pid, $started, $elapsed, $err);
	my $t0 = time;
	{
		local *STDOUT;
		open STDOUT, '>', \$quiet or die $!;
		$pid = fork();
		unless ($pid) {		# 助手：等主流程进了命令，再发信号
			select(undef, undef, undef, 0.5);
			kill 'INT', getppid();
			require POSIX;
			POSIX::_exit(0);
		}
		eval { Fink::Services::execute('sleep 2', ignore_INT => 1) };
		$err = $@;
		waitpid($pid, 0);
	}
	$elapsed = time - $t0;

	ok(Fink::CLI::interrupted($err), 'ignore_INT 期间的 ^C 最终仍抛成中断');
	cmp_ok($elapsed, '>=', 2, '而且命令没有被切断（dpkg 不会停在半装状态）');
}
