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
#
# help_preview.pl - 不进真实命令，直接看 Fink::Help 排出来的帮助长什么样
#
# 改 %align 的列宽、helpformat 的模板、或者 _align_option_text 的折行规则时，
# 跑一遍 finx 要先进配置、解析包、可能还要 sudo。这个脚本用一份假数据把渲染
# 器单独跑起来，和 `python3 lib/help.py` 的用途一样。
#
# 用法：
#   perl scripts/help_preview.pl                 按终端宽度渲染
#   perl scripts/help_preview.pl --width 60      指定列宽（调折行最常用）
#   perl scripts/help_preview.pl --width 40 | cat -v   看重定向后是否还有转义码
#   FINX_COLOR=1 perl scripts/help_preview.pl --width 60  强制上色
#
# 退出码始终 0。

use strict;
use warnings;

use FindBin;
use lib "$FindBin::RealBin/../perlmod";

use Getopt::Long;

require Fink::Help;
require Fink::FinkVersion;

my $width;
my $want_help;

Getopt::Long::Configure(qw(bundling no_ignore_case));
GetOptions(
	'width|w=i'	=> \$width,
	'help|h'	=> \$want_help,
) or die "Try '$0 --help'\n";

if ($want_help) {
	print <<"USAGE";
Usage: $0 [--width N]

Renders a sample --help screen through Fink::Help, so that alignment,
wrapping and colours can be checked without running finx itself.

  --width N   pretend the terminal is N columns wide (default: the real one)

USAGE
	exit 0;
}

# 版本号来自 basepath 下的 VERSION 文件。仓库里没装 finx 时读不到，给个占位，
# 免得预览脚本因为「没装」而失败。
{
	no warnings 'redefine';
	my $version = eval { Fink::FinkVersion::fink_version() };
	unless (defined $version) {
		*Fink::FinkVersion::fink_version = sub { '0.0.0-preview' };
	}
}

# Fink::Help 在编译期把 get_term_width 导入自己的命名空间，所以要覆盖的是
# 那一份，而不是 Fink::CLI 里的原件。
if ($width) {
	no warnings qw(redefine once);
	*Fink::Help::get_term_width = sub { $width };
}

my $dryrun;
my $yes;
my $trees;
my $nocolor;

# 一份覆盖各种情况的选项表：无值、短选项、带值的复数选项、带 ! 的否定选项、
# 以及长到必须折行的描述。
my @options = (
	[ 'dry-run|n' => \$dryrun,
		'Work out what would be done and print it, without fetching, ' .
		'building or installing anything.' ],
	[ 'yes|y' => \$yes,
		'Assume the default answer for all interactive questions, ' .
		'including the licence prompt.' ],
	[ 'trees|t=s@' => \$trees,
		'Only look in these trees. Repeat for more than one.', 'TREE' ],
	[ 'color!' => \$nocolor,
		'Colour the output; --no-color is the same as NO_COLOR=1.' ],
);

my $format = <<'FORMAT';
%intro{[options] [package...],install foo bar}
Common commands:
%align{install,install or update the named packages,14}
%align{remove,remove the named packages,14}
%align{show-deps,list run-time and compile-time dependencies,14}
%all{}
See the finx(8) manual page for a complete list of commands and options.
FORMAT

my $on = Fink::Help::color_enabled();
printf "colour is %s (%s), width %s\n\n", $on ? 'ON' : 'OFF',
	$on ? 'STDOUT is a terminal, or FINX_COLOR/CLICOLOR_FORCE is set'
	   : 'redirection, or NO_COLOR / CLICOLOR=0',
	$width || 'from the terminal';

# get_options 会先把原始条目转成内部哈希，这里照做。
my @optitems = map { Fink::Help::new_option(@$_) } @options;

print Fink::Help::expand_help(' widget', \@optitems, $format, 23);

exit 0;
