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
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110 USA.
#
#
# install_preview.pl - 一次看完 `finx install <pkg>` 全过程会打印什么
#
# 真的跑一次要解依赖、读配置、提权、可能还要联网编译，改一句文案就得重来。
# 这个脚本把整条流程的**输出**按顺序重放一遍：不联网、不提权、不碰 /opt/finx。
#
# 它复用的是真实的排版与配色（`print_breaking`、`Fink::Color` 的标记），所以
# 折行、缩进、颜色与真机一致；只有「命令本身」是编出来的 —— 那一层是子进程
# 输出（tar / patch / make / dpkg），本来就不归我们管。
#
# 用法：
#   perl scripts/install_preview.pl              按终端宽度重放
#   perl scripts/install_preview.pl --width 60   指定列宽（调折行最常用）
#   perl scripts/install_preview.pl --fail       追加一段「编译失败」的输出
#   FINX_COLOR=1 perl scripts/install_preview.pl | cat -v   强制上色
#
# 注意：脚本里的文案是**抄**自 Engine.pm / PkgVersion.pm / Services.pm 的。
# 那边改了这里不会自动跟着改 —— test/Install/preview_matches_source.t 会在
# 关键词被改掉时变红，提醒你同步。
#
# 退出码始终 0。

use strict;
use warnings;

use FindBin;
use lib "$FindBin::RealBin/../perlmod";

use Getopt::Long;

require Fink::CLI;
require Fink::FinkVersion;

my $width;
my $with_failure = 0;
my $want_help = 0;

Getopt::Long::Configure(qw(bundling no_ignore_case));
GetOptions(
	'width|w=i'	=> \$width,
	'fail'		=> \$with_failure,
	'help|h'	=> \$want_help,
) or die "Try '$0 --help'\n";

if ($want_help) {
	print <<"USAGE";
Usage: $0 [--width N] [--fail]

Replays the output of `finx install <pkg>` -- summary, prompt, fetch lines,
command echoes and the dpkg step -- without fetching, building or installing
anything.

  --width N   pretend the terminal is N columns wide (default: the real one)
  --fail      append what a failed compile looks like

USAGE
	exit 0;
}

{
	no warnings qw(redefine once);
	*Fink::CLI::get_term_width = sub { $width } if $width;

	# 版本号读自 basepath 下的 VERSION。仓库里没装 finx 时给个占位，
	# 免得预览因为「没装」而跑不起来。
	my $version = eval { Fink::FinkVersion::fink_version() };
	unless (defined $version) {
		*Fink::FinkVersion::fink_version = sub { '0.0.0-preview' };
	}
}

my $prog = $0;
print STDERR "install_preview: 模拟输出，不联网、不提权、不写文件。"
	. " 加 --fail 看失败形态。\n";

# 步骤表：kind 决定怎么打。
#
#   text  —— 走 print_breaking：折行、缩进、颜色标记都按真实规则来
#   raw   —— 裸 print：execute 的命令回显就是裸 print，不折行也不上色
#   break —— 空行
#
# prefix 用于 text，等价于 print_breaking 的第三个参数（续行缩进）。
my @steps = (
	{ kind => 'text', text => '${bold}The following package would be installed:${reset}' },
	{ kind => 'text', text => '${pkg}ncdu${reset}', prefix => ' ', linebreak => 1 },

	{ kind => 'text', text => '${bold}The following additional package would be installed:${reset}' },
	{ kind => 'text', text => '${pkg}libncursesw5-shlibs${reset}', prefix => ' ' },

	{ kind => 'text', text => 'The following package might be temporarily removed:' },
	{ kind => 'text', text => ' ncurses', prefix => ' ' },

	{ kind => 'break' },
	{ kind => 'raw',  text => 'Do you want to continue? [Y/n] ' },
	{ kind => 'break' },

	# 源码：fetch_source 在 dry-run 下打「文件名 摘要」，真下载前也会打一行
	{ kind => 'raw',  text => 'ncdu-1.22.tar.gz sha256=9c1b0f4e2a7d...' },

	# 二进制：fetch_deb 在 verbosity > 2 时打这一行，随后是 apt 的回显
	{ kind => 'raw',  text => 'Downloading ncdu_1.22-1_darwin24-arm64.deb from binary dist.' },
	{ kind => 'raw',  text => '/opt/finx/bin/apt-get --ignore-breakage --download-only install ncdu=1.22-1' },

	{ kind => 'break' },

	# 以下都是 execute 的命令回显：sudo -u fink-bld [ENV] sh -c '<命令>'
	# （[ENV] 是真实代码里的占位，实际会展开成一长串 KEY=VALUE）
	# 用 q!...! 而不是 q{...}：命令里带 sh -c 的单引号，q{} 的右花括号容易被看错。
	{ kind => 'echo', text => q!sudo -u fink-bld [ENV] sh -c 'mkdir -p /opt/finx/src/finx.build/ncdu-1.22-1'! },
	{ kind => 'echo', text => q!sudo -u fink-bld [ENV] sh -c 'cd /opt/finx/src/finx.build/ncdu-1.22-1 && tar xf /opt/finx/src/ncdu-1.22.tar.gz'! },
	{ kind => 'echo', text => q!sudo -u fink-bld [ENV] sh -c 'cd /opt/finx/src/finx.build/ncdu-1.22-1/ncdu-1.22 && patch -p1 < /opt/finx/finx/dists/15.0/main/finkinfo/base/ncdu.patch'! },
	{ kind => 'echo', text => q!sudo -u fink-bld [ENV] sh -c 'cd /opt/finx/src/finx.build/ncdu-1.22-1/ncdu-1.22 && CFLAGS="-O2 -g" ./configure --prefix=/opt/finx'! },
	{ kind => 'echo', text => q!sudo -u fink-bld [ENV] sh -c 'cd /opt/finx/src/finx.build/ncdu-1.22-1/ncdu-1.22 && make'! },
	{ kind => 'echo', text => q!sudo -u fink-bld [ENV] sh -c 'cd /opt/finx/src/finx.build/ncdu-1.22-1/ncdu-1.22 && make install DESTDIR=/opt/finx/src/finx.build/root-ncdu-1.22-1'! },
	{ kind => 'echo', text => q!sudo -u fink-bld [ENV] sh -c 'cd /opt/finx/src/finx.build/root-ncdu-1.22-1 && /opt/finx/bin/dpkg-deb -b ...'! },

	{ kind => 'break' },

	# dpkg 这一步是子进程的输出，直通终端，没有颜色
	{ kind => 'raw',  text => '/opt/finx/bin/dpkg -i /opt/finx/finx/debs/ncdu_1.22-1_darwin24-arm64.deb' },
	{ kind => 'raw',  text => 'Selecting previously unselected package ncdu.' },
	{ kind => 'raw',  text => 'Unpacking ncdu (1.22-1) ...' },
	{ kind => 'raw',  text => 'Setting up ncdu (1.22-1) ...' },
);

if ($with_failure) {
	push @steps,
		{ kind => 'break' },
		{ kind => 'text', text => 'Failed: execution of make, exit code 2' },
		{ kind => 'break' },
		{ kind => 'text', text => '${error}phase compile: ncdu-1.22-1 failed${reset}' },
		{ kind => 'text', text => 'Before reporting any errors, please run "finx selfupdate" and try again.' },
		{ kind => 'text', text => 'If you continue to have issues, please check to see if the FAQ on Fink\'s website solves the problem.' },
		{ kind => 'break' },
		{ kind => 'raw',  text => 'Closed logfile /tmp/finx-build-log_ncdu_1.22-1_2026.11.06-14.55.02' };
}

foreach my $step (@steps) {
	if ($step->{kind} eq 'break') {
		print "\n";
	} elsif ($step->{kind} eq 'raw') {
		print $step->{text}, "\n";
	} elsif ($step->{kind} eq 'echo') {
		# execute 的命令回显：整行压暗
		require Fink::Color;
		print Fink::Color::colorize("%{dim}$step->{text}%{reset}"), "\n";
	} else {
		Fink::CLI::print_breaking($step->{text}, $step->{linebreak},
			$step->{prefix});
	}
}

exit 0;
