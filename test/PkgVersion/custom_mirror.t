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
# `FINX_SOURCECODE_DOMAIN` 必须真的改变取源码的地址。
#
# 这条链路以前是断的：变量只被 `finx mirror` 读，`PkgVersion` 拿的是 .info 里
# 写死的那串，于是用户设了镜像地址却没有任何效果。这里钉住接上之后的行为，
# 尤其是「只换官方池那一串，别把上游自己的 Secondary 丢掉」。

use strict;
use Test::More tests => 10;
use Fink::Config;

my @VARS = qw(FINX_SOURCECODE_DOMAIN FINX_MIRROR_DOMAIN);
my %saved = map { $_ => $ENV{$_} } @VARS;
END {
	while (my ($k, $v) = each %saved) {
		if (defined $v) { $ENV{$k} = $v } else { delete $ENV{$k} }
	}
}
sub clear_env { delete @ENV{@VARS} }

my $config = Fink::Config->new_with_path('basepath/etc/finx.conf');

require_ok('Fink::PkgVersion');		# 1

my $OFFICIAL = 'https://github.com/Fincote/Finx-source/releases/download/src-1';
my $MIRROR   = 'https://mirror.repohub.top/Finx/sourcecode';

# 每次都重新读，因为 get_custom_mirror 把结果缓存在对象里。
sub sites {
	my $pv = (Fink::PkgVersion->pkgversions_from_info_file(
		"PkgVersion/custom-mirror.info"))[0];
	return () unless $pv;
	my $m = $pv->get_custom_mirror();
	return () unless ref $m;
	return $m->list_by_level(3);
}

# --- 1. 没设变量：一个字都不许动 -----------------------------------------

{
	clear_env();
	my %site = map { $_ => 1 } sites();
	ok($site{$OFFICIAL}, 'without an override the .info address is used as-is');
}

# --- 2. 设了 FINX_SOURCECODE_DOMAIN --------------------------------------

{
	clear_env();
	$ENV{FINX_SOURCECODE_DOMAIN} = $MIRROR;
	my %site = map { $_ => 1 } sites();
	ok($site{$MIRROR}, 'the override replaces the official pool address');
	ok(!$site{$OFFICIAL}, 'and the official one is gone');
	ok($site{'http://ftpmirror.gnu.org/non-gnu/custom-mirror/source/feature/1.0/'},
		'a Secondary from elsewhere in the same field is kept');
}

# --- 3. 只设基址也一样 ---------------------------------------------------

{
	clear_env();
	$ENV{FINX_MIRROR_DOMAIN} = 'https://mirror.repohub.top/Finx';
	my %site = map { $_ => 1 } sites();
	ok($site{$MIRROR}, 'FINX_MIRROR_DOMAIN derives the source pool too');
}

# --- 4. 空串不算设过 -----------------------------------------------------

{
	clear_env();
	$ENV{FINX_SOURCECODE_DOMAIN} = '   ';
	my %site = map { $_ => 1 } sites();
	ok($site{$OFFICIAL}, 'a blank value does not count as an override');
	ok(!$site{$MIRROR}, 'and nothing is redirected');
}

# --- 5. 没有被改写的包不受影响 -------------------------------------------
#
# base-files 那类 CustomMirror 根本不指向我们的池子，用户设了 sourcecode
# 也不该把它的 SourceForge 地址换掉。

{
	clear_env();
	require Fink::Domains;
	my $field = "Primary: http://downloads.sourceforge.net\n";
	my $out = Fink::PkgVersion::_custom_mirror_field($field);
	is($out, $field, 'a field that never pointed at our pool is left alone');

	$ENV{FINX_SOURCECODE_DOMAIN} = $MIRROR;
	$out = Fink::PkgVersion::_custom_mirror_field("Primary: $OFFICIAL\n");
	is($out, "Primary: $MIRROR\n", 'a field that did gets rewritten');
}
