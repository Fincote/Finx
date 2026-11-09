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
# 安装/删除时的输出形状：`==>` 那一行，以及子进程输出的前缀。
#
# 三件事只有改动者自己知道，钉在这里：
#   1. 箭头的颜色是进程级状态（正常绿 / 删除橙 / 失败红）。它必须能被设定，
#      否则删除类命令的输出会和安装时一模一样。
#   2. 子进程的输出是**接管**来的，所以退出码必须原样传回 —— 一旦传错，
#      构建失败会被当成成功，或者反过来。
#   3. stderr 必须并进 stdout：不并的话两股输出各写各的，前缀下会混行。

use strict;
use Test::More tests => 15;

use Fink::Color;
use Fink::CLI qw(capture print_step);
use Fink::Services ();

sub clear_colour { delete @ENV{qw(NO_COLOR CLICOLOR CLICOLOR_FORCE FINX_COLOR)} }
sub force_colour { clear_colour(); $ENV{FINX_COLOR} = 1 }

# --- 1. `==>` 行 ---------------------------------------------------------

{
	clear_colour();
	my ($out, $err) = ('', '');
	capture { print_step("The following package would be installed:") }
		\$out, \$err;
	is($out, "==> The following package would be installed:\n",
		'without colour a step is the arrow, a space and the text');
}

{
	force_colour();
	my ($out, $err) = ('', '');
	capture { print_step("Hello") } \$out, \$err;
	like($out, qr/\e\[32m==>\e\[0m/, 'the arrow is green by default');
	like($out, qr/\e\[1mHello\e\[0m/,
		'and the text is bold, not black: black vanishes on a dark theme');
}

{
	force_colour();
	Fink::Color::set_step_role('orange');
	my ($out, $err) = ('', '');
	capture { print_step("Removing ncurses") } \$out, \$err;
	like($out, qr/\e\[38;5;208m==>/, 'removal switches the arrow to orange');
	Fink::Color::set_step_role('ok');
}

{
	force_colour();
	my ($out, $err) = ('', '');
	capture { print_step("Failed: nope", 'error') } \$out, \$err;
	like($out, qr/\e\[1;31m==>/, 'a failure can force a red arrow');
}

# 折行后，续行缩进四个可见列 —— 与箭头右侧的文字对齐。
{
	clear_colour();
	local $Fink::CLI::linelength = 40;
	my ($out, $err) = ('', '');
	capture { print_step("one two three four five six seven eight nine ten") }
		\$out, \$err;
	my @lines = split /\n/, $out;
	cmp_ok(scalar(@lines), '>', 1, 'a long step wraps');
	like($lines[1], qr/^    \S/, 'and the continuation lines up under the text');
}

# --- 2. 子进程输出 -------------------------------------------------------

{
	my $out = '';
	open(my $fh, '>', \$out) or die $!;
	my $saved = select($fh);
	my $rc;
	{
		local $Fink::Color::STEP_ROLE = 'ok';
		$rc = Fink::Services::_run_prefixed('PF ', 'echo', 'a');
	}
	select($saved);
	close $fh;

	is($rc, 0, 'a command that succeeds reports 0');
	is($out, "PF a\n", 'and its output comes back with the prefix');
}

{
	my $out = '';
	open(my $fh, '>', \$out) or die $!;
	my $saved = select($fh);
	my $rc = Fink::Services::_run_prefixed('PF ', 'sh', '-c', 'echo e 1>&2');
	select($saved);
	close $fh;

	like($out, qr/^PF e/m, 'stderr is merged, so it is prefixed too');
	is($rc, 0, 'redirecting to stderr does not change the exit code');
}

{
	my $out = '';
	open(my $fh, '>', \$out) or die $!;
	my $saved = select($fh);
	my $rc = Fink::Services::_run_prefixed('', 'sh', '-c', 'exit 7');
	select($saved);
	close $fh;

	is($rc >> 8, 7, 'a failing command hands back its exit code');
}

# --- 3. 明确作答 ---------------------------------------------------------

{
	clear_colour();
	local *STDIN;
	open(STDIN, '<', \"\ny\n") or die "can't fake stdin: $!";

	my ($out, $err) = ('', '');
	my $answer = capture {
		Fink::CLI::prompt_boolean("Do you want to continue?",
			default => 1, arrow => 1, require_answer => 1);
	} \$out, \$err;

	is($answer, 1, 'an empty answer is rejected, then y is accepted');
	like($out, qr/Please answer y or n/, 'and the user is asked again');
	like($out, qr/==> .*Do you want to continue\?/, 'the prompt carries the arrow');
}

clear_colour();
