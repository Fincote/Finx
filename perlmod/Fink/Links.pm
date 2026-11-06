# -*- mode: Perl; tab-width: 4; -*-
#
# Fink - a package manager that downloads source and installs it
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

package Fink::Links;

# 载荷自带的符号链接，解析后必须落在安装根目录内。
#
# 与 finx-install/lib/links.sh 是同一条规则的两套实现：那边管种子安装器
# （curl | bash，一次一个 60 MB 的 tar），这边管 dpkg 装 .deb，以及 make
# 里对产物树的审计。两边的豁免表必须一致，改动时一起改。
#
# 为什么需要这条：解包工具只过滤成员**名字**里的 "../"，与链接的**目标**无关。
# 一个包可以合法地含有
#
#     lib/innocent.dylib -> /Users/someone/.ssh/id_rsa
#
# 名字老实待在树内，指向的地方却是任何位置。装完之后，任何顺着这个链接去读或
# 去写的代码都会落到树外。
#
# 判定按**路径分段**比较，不是字符串前缀：/opt/finx2 不是 /opt/finx 的子目录，
# 而 "/opt/finx/../evil" 归一化之后是 "/opt/evil"。

use strict;
use warnings;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
	&canon_path
	&is_confined
	&exempt_list
	&parse_deb_listing
	&offending_in_deb
	&offending_in_tree
);

our $VERSION = 1.00;

# 唯一开口子的地方，两条理由必须同时成立：SIP 连 root 都拒绝写这些路径（顺着
# 链接去写不成立），且那里只有系统自带的二进制与库、不含隐私文件（顺着链接去读
# 也不成立）。其余一律不例外，包括 /Users、/Library 里 Apple/ 以外的部分、
# /private、/opt、/etc、/var。
our @EXEMPT = qw(
	/bin /sbin /usr/bin /usr/sbin /usr/lib /usr/libexec
	/System /Library/Apple
);

=pod

=head1 NAME

Fink::Links - reject symbolic links that point outside the install prefix

=head1 DESCRIPTION

A payload is allowed to carry symlinks, but every one of them must resolve
inside the install root, or to one of the exempt system locations. Nothing
downstream follows a link it should not have accepted: dpkg looks only at
member names, and the postinst runs as root.

=cut

=item exempt_list

	my $text = exempt_list();

The exempt locations as one comma-separated line, for error messages.

=cut

sub exempt_list {
	return join(', ', @EXEMPT);
}

=item canon_path

	my $abs = canon_path($path);

Lexically normalise an absolute path: drop empty and C<.> segments, and let
C<..> pop one. The filesystem is never consulted, so a dangling link is
judged exactly like a live one - a link to C</opt/nothing-here> becomes a
real escape the moment something creates that path.

=cut

sub canon_path {
	my $path = shift;
	my @out;
	for my $seg (split(m{/}, $path)) {
		next if $seg eq '' or $seg eq '.';
		if ($seg eq '..') {
			pop @out;
			next;
		}
		push @out, $seg;
	}
	return '/' . join('/', @out);
}

=item is_confined

	my $ok = is_confined($absolute_path);

True when the path is the root itself, sits under it, or sits under one of
the exempt locations. Comparison is by path segment, so C</usrlocal> is not
treated as C</usr>.

=cut

sub is_confined {
	my $path = shift;
	for my $base (@EXEMPT) {
		return 1 if $path eq $base;
		return 1 if index($path, "$base/") == 0;
	}
	return 0;
}

# 把一条链接的目标解成绝对路径。相对目标相对于链接自身所在目录。
sub _resolve {
	my ($link, $target) = @_;
	return canon_path($target) if $target =~ m{^/};
	(my $dir = $link) =~ s{/[^/]*$}{};
	$dir = '/' if $dir eq '';
	return canon_path("$dir/$target");
}

# 链接本身能否被接受。$root 也必须先归一化，否则 /opt/finx/ 这种写法会让
# 前缀比较全部失配。
sub _acceptable {
	my ($link, $target, $canon_root) = @_;
	my $resolved = _resolve($link, $target);
	return 1 if $resolved eq $canon_root;
	return 1 if index($resolved, "$canon_root/") == 0;
	return is_confined($resolved);
}

=item parse_deb_listing

	my @offending = parse_deb_listing($text, $root);

Takes the output of C<dpkg-deb -c> and returns the offending links as
C<< name -> target >> strings, with C<name> relative to C<$root>.

Parsing rather than unpacking keeps this from touching the filesystem twice
per package. The name is split off after the date and time columns, and the
target after the B<first> C<< -> >> - a payload file name cannot contain one,
a target can, and splitting on the last would let C<< /usr/local/t -> y >>
pass as the harmless relative C<y>.

=cut

sub parse_deb_listing {
	my ($text, $root) = @_;
	my $canon_root = canon_path($root);
	my @bad;
	for my $line (split(m{\n}, $text)) {
		# 只有符号链接有意义，且必须有目标
		next unless $line =~ m{^l};
		next unless $line =~ m{^(?:\S+\s+){5}(.*)$};
		my $rest = $1;
		# 按**第一个** " -> " 切，不是最后一个。产物里的文件名不可能含箭头，
		# 目标却可能："> /usr/local/t -> y" 按最后切会把目标看成 y（树内）而
		# 放行，按第一个切才看得到真正的绝对路径。
		next unless $rest =~ m{^(.*?) -> (.*)$};
		my ($name, $target) = ($1, $2);
		$name =~ s{^\./}{};
		next if $name eq '';
		# 相对目标要相对于链接自身所在目录，而那个目录只能从前缀算起 ——
		# 传 "/$name" 会让 "-> ../bin/finx" 解到 /bin/finx 去。
		next if _acceptable("$canon_root/$name", $target, $canon_root);
		push @bad, "$name -> $target";
	}
	return @bad;
}

=item offending_in_deb

	my @offending = offending_in_deb($debfile, $root, $dpkgdeb);

Lists a C<.deb>'s symlinks via C<dpkg-deb -c> and returns the offending
ones. C<$dpkgdeb> defaults to F<dpkg-deb> on PATH; callers inside finx should
pass the one from the prefix, because PATH is not trustworthy there.

=cut

sub offending_in_deb {
	my ($debfile, $root, $dpkgdeb) = @_;
	$dpkgdeb = 'dpkg-deb' unless defined $dpkgdeb and length $dpkgdeb;
	my $text = qx{"$dpkgdeb" -c "$debfile" 2>/dev/null};
	return () if $? != 0 or not defined $text;
	return parse_deb_listing($text, $root);
}

=item offending_in_tree

	my @offending = offending_in_tree($root);

Walks an already-unpacked tree. Used by the seed installer path and by the
build-time audit; links are never followed, only read.

=cut

sub offending_in_tree {
	require File::Find;
	my ($root) = @_;
	my $canon_root = canon_path($root);
	my @bad;
	File::Find::find(
		{
			no_chdir => 1,
			wanted   => sub {
				return unless -l $File::Find::name;
				my $target = readlink $File::Find::name;
				return unless defined $target;
				my $rel = $File::Find::name;
				$rel =~ s{^\Q$canon_root\E/?}{};
				return if _acceptable($File::Find::name, $target, $canon_root);
				push @bad, "$rel -> $target";
			},
		},
		$canon_root
	);
	return @bad;
}

1;

# Local Variables:
# mode: perl
# End:
