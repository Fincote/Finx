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
# 预编译包这条通道：自己下、自己校验、装的时候仍是 `dpkg -i` 本地文件。
#
# 钉在这儿的三件事，每一件都只有改动者自己知道：
#   1. 资产名的形状必须与镜像站上的一致（带 @、带 Darwin 主版本）。名字差
#      一个字符就是 404，而那看起来像「镜像站没同步」。
#   2. 校验失败必须删掉文件再 die。留一个坏 .deb 在缓存里，下一次
#      find_debfile 会直接拿去 dpkg -i —— 而它的 postinst 以 root 执行。
#   3. --dry-run 不许落盘，也不许建目录。

use strict;
use Test::More tests => 22;
use Fink::Config;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use File::Path qw(mkpath);

my @VARS = qw(FINX_DEB_DOMAIN);
my %saved = map { $_ => $ENV{$_} } @VARS;
END {
	while (my ($k, $v) = each %saved) {
		if (defined $v) { $ENV{$k} = $v } else { delete $ENV{$k} }
	}
	# 我们自己下的东西留在 test/basepath 里会让下一次 structure 检查看见
	# 未跟踪的文件，所以跑完就清掉。
	require File::Path;
	my $dir = eval { Fink::PkgVersion::bottle_cache_dir() };
	File::Path::rmtree($dir) if defined $dir && -e $dir;
}

my $config = Fink::Config->new_with_path('basepath/etc/finx.conf');
$config->set_param("UseBinaryDist", "true");

require Fink::PkgVersion;

my $INFO = 'PkgVersion/bottle-test.info';

sub new_pv {
	return (Fink::PkgVersion->pkgversions_from_info_file($INFO))[0];
}

# 一台本机镜像：<root>/<包名>/<资产名> 与 <root>/<包名>/SHA256SUMS
sub make_mirror {
	my ($pv, %opt) = @_;
	my $root = tempdir(CLEANUP => 1);
	my $dir  = "$root/" . $pv->get_name();
	mkpath($dir);

	my $file = $pv->get_bottle_name();
	my $body = "not a real .deb, just bytes\n";
	open(my $fh, '>', "$dir/$file") or die $!;
	print $fh $body;
	close $fh;

	my $sum = Fink::Checksum->new('SHA256')->get_checksum("$dir/$file");
	my $listed = $opt{wrong_sum} ? ('0' x 64) : $sum;
	my $listed_name = $opt{other_platform}
		? 'something-else.darwin1-x86_64.deb' : $file;
	open($fh, '>', "$dir/SHA256SUMS") or die $!;
	printf $fh "%s  %s\n", $listed, $listed_name;
	close $fh;

	return $root;
}

# 每次调用都把工作目录还原：万一哪天 _download_to 的兜底没了，这里也不会
# 变成「后面按相对路径找 fixture 全都失败」那种难查的连锁故障。
sub fetch_in_place {
	my ($pv, $dryrun) = @_;
	my $cwd = getcwd();
	my $err;
	eval { $pv->fetch_deb($dryrun, $pv); };
	$err = $@;
	chdir $cwd;
	return $err;
}

# --- 1. 资产名与 URL 的形状 ----------------------------------------------

{
	my $pv = new_pv();
	like($pv->get_bottle_name(), qr/^bottle-test\@1\.2-3\.darwin\d+-[A-Za-z0-9_]+\.deb$/,
		'asset name is <name>@<version>-<revision>.darwin<D>-<arch>.deb');
	like($pv->get_bottle_name(), qr/darwin\d+-/, 'the Darwin major is in the name');

	delete $ENV{FINX_DEB_DOMAIN};
	is($pv->get_bottle_url(),
		'https://github.com/Fincote/debs/releases/download/bottle-test/'
		. $pv->get_bottle_name(),
		'the default domain yields the published layout');

	$ENV{FINX_DEB_DOMAIN} = 'https://mirror.repohub.top/Finx/bottle';
	is($pv->get_bottle_url(),
		'https://mirror.repohub.top/Finx/bottle/bottle-test/'
		. $pv->get_bottle_name(),
		'the environment overrides it, keeping <name>/<asset>');
}

# --- 2. 下载、校验、被 find_debfile 找到 ---------------------------------

{
	my $pv   = new_pv();
	my $root = make_mirror($pv);
	$ENV{FINX_DEB_DOMAIN} = "file://$root";

	is(fetch_in_place($pv, 0), '', 'a good download does not die');

	my $found = $pv->find_debfile();
	ok(defined $found, 'find_debfile sees the downloaded bottle');
	like($found, qr/\Q@{[ $pv->get_bottle_name() ]}\E$/,
		'and it is the file we just fetched');
	is($found, Fink::PkgVersion::bottle_cache_dir() . '/' . $pv->get_bottle_name(),
		'from our own cache directory, not apt archives');
}

# --- 3. --dry-run 不落盘 --------------------------------------------------

{
	my $pv   = new_pv();
	my $root = make_mirror($pv);
	$ENV{FINX_DEB_DOMAIN} = "file://$root";

	my $dir   = Fink::PkgVersion::bottle_cache_dir();
	my $fresh = !-e $dir;
	File::Path::rmtree($dir) if -e $dir;

	my $err = fetch_in_place($pv, 1);
	is($err, '', 'dry-run does not die');
	ok(!-e $dir, 'dry-run creates no cache directory at all');
	ok(!-e "$dir/" . $pv->get_bottle_name(), 'and no .deb');
}

# --- 4. 校验失败：删文件、不装 -------------------------------------------

{
	my $pv   = new_pv();
	my $root = make_mirror($pv, wrong_sum => 1);
	$ENV{FINX_DEB_DOMAIN} = "file://$root";

	my $dir = Fink::PkgVersion::bottle_cache_dir();
	File::Path::rmtree($dir) if -e $dir;

	my $err = fetch_in_place($pv, 0);
	like($err, qr/Checksum mismatch/, 'a wrong checksum is fatal');
	ok(!-e "$dir/" . $pv->get_bottle_name(),
		'and the bad .deb is deleted, so dpkg can never see it');
	ok(defined $err && $err =~ /Nothing was installed/, 'the message says so');
}

# --- 5. 依赖解析阶段问「有没有预编译包」 --------------------------------
#
# 这条决定了走哪条路：apt 的索引里没有我们的包（sources.list 不会写进去，
# 而 apt 0.5.4 也没有 https method），所以真正的答案是镜像的 SHA256SUMS。

{
	my $pv   = new_pv();
	my $root = make_mirror($pv);
	$ENV{FINX_DEB_DOMAIN} = "file://$root";

	ok($pv->is_bottleable(), 'a listed asset means the package is available');
	ok($pv->is_bottleable(1), 'and --dry-run says yes without asking');

	# 镜像上没有它（换一台空的）
	$ENV{FINX_DEB_DOMAIN} = 'file:///nonexistent-mirror-xyzzy';
	ok(!$pv->is_bottleable(),
		'an unreachable mirror means "no", so the source build happens instead');
	ok($pv->is_bottleable(1), 'but the dry-run still assumes it might be there');

	# UseBinaryDist 关着时一个问题都不问
	$config->set_param("UseBinaryDist", "false");
	ok(!$pv->is_bottleable(1), 'nothing is prebuilt when the option is off');
	$config->set_param("UseBinaryDist", "true");
}

{
	my $pv   = new_pv();
	my $root = make_mirror($pv, other_platform => 1);
	$ENV{FINX_DEB_DOMAIN} = "file://$root";

	my $err = fetch_in_place($pv, 0);
	like($err, qr/no entry for/, 'a platform missing from SHA256SUMS is fatal');
	like($err, qr/[Bb]uild .* from source|from source/,
		'and the message points at building from source');
	ok(!-e Fink::PkgVersion::bottle_cache_dir() . '/' . $pv->get_bottle_name(),
		'nothing was downloaded');
}
