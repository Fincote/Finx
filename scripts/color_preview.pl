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
# color_preview.pl - 一次看完所有颜色标记的实际效果
#
# 调色时最烦的是一路「改 %PALETTE、编译、跑一条长命令、在几十行输出里找那一行」。
# 这个脚本把每个标记都印出来；重定向到文件时还能顺便确认「关闭上色时标记是否被
# 干净地删掉」。
#
# 用法：
#   perl scripts/color_preview.pl              在终端里看效果
#   perl scripts/color_preview.pl | cat        看重定向后的样子（应无转义码）
#   FINX_COLOR=1 perl scripts/color_preview.pl | cat -v   强制上色并显示转义码
#
# 退出码始终 0。

use strict;
use warnings;

use FindBin;
use lib "$FindBin::RealBin/../perlmod";

require Fink::Color;

my @tokens = Fink::Color::tokens();
my %palette = Fink::Color::palette();

my @semantic_names = qw(step cmd flag value section prog pkg error warn ok);
my %is_semantic = map { $_ => 1 } @semantic_names;

my @semantic = grep { $is_semantic{$_} } @tokens;
my @basic = grep { !$is_semantic{$_} } @tokens;

my $on = Fink::Color::enabled();

printf "colour is %s (%s)\n\n", $on ? 'ON' : 'OFF',
	$on ? 'STDOUT is a terminal, or FINX_COLOR/CLICOLOR_FORCE is set'
	   : 'redirection, or NO_COLOR / CLICOLOR=0';

sub dump_group {
	my ($title, @names) = @_;
	printf "%s:\n", $title;
	my $width = 0;
	foreach my $name (@names) {
		$width = length $name if length $name > $width;
	}
	foreach my $name (@names) {
		my $sample = Fink::Color::colorize('${' . $name . '}sample text${reset}');
		printf "  %-*s  %s\n", $width, $name, $sample;
	}
	print "\n";
}

dump_group('basic', @basic);
dump_group('semantic', @semantic);

print "\na real message, wrapped by the same code print_breaking uses:\n\n";

my $message = '${warn}WARNING${reset}: ${pkg}ncdu${reset} does not record '
	. 'its library dependency, so ${cmd}finx remove${reset} '
	. '${flag}libncursesw5-shlibs${reset} would break it silently.';
foreach my $line (Fink::Color::wrap_marked($message, 72, '', '  ')) {
	print "  $line\n";
}

print "\ndiagnostic messages, the way print_breaking renders them:\n\n";

# ERROR / WARNING 由 Fink::Color::style_diagnostic 自动上色并加程序标记，
# 调用点写的仍然只是纯文本。这里演示两种角色各一行。
foreach my $msg ('ERROR: apt-get is missing; install the apt package first.',
		'WARNING: no checksum recorded for ncdu-1.22.tar.gz') {
	print '  ', join('', Fink::Color::wrap_marked(
		Fink::Color::style_diagnostic($msg), 72, '  ', '    ')), "\n";
}

print "\nstep heading, the way install.sh prints it:\n\n";
print '  ', Fink::Color::colorize('${step}==>${reset} ${bold}Checking host${reset}'), "\n";

print "\nraw escapes (what actually lands on the terminal):\n";
foreach my $name (@tokens) {
	my $escape = $palette{$name};
	$escape =~ s/\033/^[/g;
	printf "  %-10s %s\n", $name, $escape;
}

exit 0;
