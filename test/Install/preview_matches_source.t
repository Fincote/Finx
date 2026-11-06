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
# scripts/install_preview.pl 有没有跟真代码走散。
#
# 那个脚本的文案是**抄**过来的：真代码里改一句话，预览不会自己变。抄错本身
# 不会让任何功能失效，只会让人对着一份过期的「参考输出」调颜色 —— 那种错最难
# 发现，因为没有东西会报错。
#
# 所以这里两头钉：关键词既要还在源文件里，也要还在预览输出里。源文件改了，
# 第一条断言红，提示你去同步预览；预览被改坏了，第二条红。

use strict;
use Test::More tests => 16;

my @fragments = (
	[ '../perlmod/Fink/Engine.pm',
		'The following ',                  '安装摘要的引子' ],
	[ '../perlmod/Fink/Engine.pm',
		'additional package ',             '附加包那一段' ],
	[ '../perlmod/Fink/Engine.pm',
		'might be temporarily removed',    '可能被临时移除的包' ],
	[ '../perlmod/Fink/Engine.pm',
		'Do you want to continue?',        '继续确认' ],
	[ '../perlmod/Fink/PkgVersion.pm',
		'from binary dist.',               '取 .deb 的那一行' ],
	[ '../perlmod/Fink/Services.pm',
		'### execution of ',               '命令失败的提示' ],
	[ '../perlmod/Fink/Services.pm',
		'[ENV] sh -c ',                    '命令回显的前缀' ],
);

my %source;
sub source_of {
	my $file = shift;
	unless (exists $source{$file}) {
		open my $fh, '<', $file or die "can't read $file: $!\n";
		local $/;
		$source{$file} = <$fh>;
		close $fh;
	}
	return $source{$file};
}

my $preview = `$^X ../scripts/install_preview.pl --width 78 --fail 2>/dev/null`;
isnt($preview, '', 'install_preview.pl 能跑出东西来');

foreach my $f (@fragments) {
	my ($file, $fragment, $what) = @$f;
	like(source_of($file), qr/\Q$fragment\E/,
		"$file 里还有「$what」");
	like($preview, qr/\Q$fragment\E/,
		"预览里也还有「$what」");
}

# 关闭上色时预览不能留下转义码：它常被重定向到文件里对照。
unlike($preview, qr/\033/, '重定向时没有转义码');
