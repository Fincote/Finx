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
# 地址解析与 `finx mirror` 的展示层。
#
# 三件容易写错、且都不会让别的测试变红的事，钉在这里：
#   1. 解析只有两个来源：环境变量、内置默认。多一个来源（文件）就意味着
#      过期数据能悄悄压过改对的代码 —— 这正是 mirror/URL 那批单行文件的死法。
#   2. 打码不能泄露长度，也不能把 path 里的 @ 当成凭据。
#   3. 非法地址必须拒绝得早：它会被拼进 URL、写进错误信息，也可能被 shell 用。

use strict;
use Test::More tests => 29;

require Fink::Domains;
require Fink::Engine;

my @VARS = qw(FINX_API_DOMAIN FINX_DEB_DOMAIN FINX_SOURCE_DOMAIN
		FINX_SOURCECODE_DOMAIN FINX_SELFUPDATE_DOMAIN);
my %saved = map { $_ => $ENV{$_} } @VARS;
END {
	while (my ($k, $v) = each %saved) {
		if (defined $v) { $ENV{$k} = $v } else { delete $ENV{$k} }
	}
}

sub clear_env { delete @ENV{@VARS} }

# --- 1. 环境变量 → 内置默认，没有第三个来源 ------------------------------

{
	clear_env();
	is(Fink::Domains::domain('bottle'),
		'https://github.com/Fincote/debs/releases/download',
		'bottle falls back to the built-in default');
	is(Fink::Domains::domain('api'), '',
		'a kind with no default resolves to the empty string');
	ok(!Fink::Domains::is_custom('bottle'), 'is_custom is false when unset');

	$ENV{FINX_DEB_DOMAIN} = 'https://mirror.example.top/Finx/bottle';
	is(Fink::Domains::domain('bottle'), 'https://mirror.example.top/Finx/bottle',
		'the environment variable wins over the default');
	ok(Fink::Domains::is_custom('bottle'), 'is_custom is true when set');
}

# --- 2. 规范化 ------------------------------------------------------------

{
	clear_env();
	$ENV{FINX_DEB_DOMAIN} = "  https://mirror.example.top/Finx/bottle///  ";
	is(Fink::Domains::domain('bottle'), 'https://mirror.example.top/Finx/bottle',
		'surrounding whitespace and trailing slashes are stripped');
}

# --- 3. 校验 --------------------------------------------------------------

{
	clear_env();
	$ENV{FINX_DEB_DOMAIN} = 'http://mirror.example.top/x';
	ok(!eval { Fink::Domains::domain('bottle'); 1 },
		'plain HTTP to a remote host is refused');

	$ENV{FINX_DEB_DOMAIN} = 'http://127.0.0.1:8080/x';
	is(eval { Fink::Domains::domain('bottle') }, 'http://127.0.0.1:8080/x',
		'plain HTTP to loopback is allowed for offline testing');

	$ENV{FINX_DEB_DOMAIN} = 'http://user:pw@127.0.0.1:8080/x';
	is(eval { Fink::Domains::domain('bottle') }, 'http://user:pw@127.0.0.1:8080/x',
		'the loopback check strips userinfo before looking at the host');

	$ENV{FINX_DEB_DOMAIN} = 'ftp://mirror.example.top/x';
	ok(!eval { Fink::Domains::domain('bottle'); 1 }, 'ftp is refused');

	$ENV{FINX_DEB_DOMAIN} = 'https://mirror.example.top/$(id)';
	ok(!eval { Fink::Domains::domain('bottle'); 1 },
		'a value with a dollar sign is refused');

	$ENV{FINX_DEB_DOMAIN} = 'mirror.example.top/x';
	ok(!eval { Fink::Domains::domain('bottle'); 1 }, 'a value with no scheme is refused');
}

# --- 4. 打码 --------------------------------------------------------------

{
	my $url = 'https://user:secret@mirror.example.top/Finx/bottle';

	is(Fink::Domains::masked_url($url, 0, 0),
		'https://user:******@mirror.example.top/Finx/bottle',
		'the password is masked, the user name is kept');
	is(Fink::Domains::masked_url($url, 0, 1),
		'https://******:******@mirror.example.top/Finx/bottle',
		'--hide-user also masks the user name');
	is(Fink::Domains::masked_url($url, 1, 0), $url,
		'--show-password prints the value unchanged');

	is(Fink::Domains::redact_url($url),
		'https://user:***@mirror.example.top/Finx/bottle',
		'redact_url keeps the user name and replaces the password');

	# path 里的 @ 是合法文件名，不能当成凭据位置
	my $deb = 'https://github.com/Fincote/debs/releases/download/ncdu/ncdu@1.22-1.darwin24-arm64.deb';
	is(Fink::Domains::redact_url($deb), $deb,
		'an @ inside the path is not mistaken for credentials');
	is(Fink::Domains::masked_url($deb, 0, 0), $deb,
		'and masked_url leaves it alone too');
}

# --- 5. rows() 的来源标记 -------------------------------------------------

{
	clear_env();
	$ENV{FINX_SOURCECODE_DOMAIN} = 'https://mirror.example.top/Finx/deps';
	my %by_name = map { $_->{name} => $_ } Fink::Domains::rows(0, 0);

	is($by_name{bottle}{source}, 'default', 'an unset variable reports "default"');
	is($by_name{sourcecode}{source}, 'env', 'an overridden variable reports "env"');
	is($by_name{api}{source}, 'unset', 'a kind with no default reports "unset"');
	is($by_name{api}{value}, '', 'and its value is empty, not a fake address');
}

# --- 6. --raw ------------------------------------------------------------

{
	clear_env();
	$ENV{FINX_DEB_DOMAIN} = 'https://mirror.example.top/Finx/bottle';
	my @rows = Fink::Domains::rows(0, 0);

	my $all = Fink::Engine::_mirror_raw(\@rows, 0);
	like($all, qr/^export FINX_DEB_DOMAIN=/m, '--raw exports the overridden variable');
	like($all, qr/^export FINX_SOURCE_DOMAIN=/m, '--raw also pins the defaults');
	like($all, qr/^# FINX_API_DOMAIN/m,
		'a kind with nothing to point at becomes a comment, not an empty export');

	my $only = Fink::Engine::_mirror_raw(\@rows, 1);
	like($only, qr/^export FINX_DEB_DOMAIN=/m, '--only-set keeps the overridden one');
	unlike($only, qr/^export FINX_SOURCE_DOMAIN=/m, '--only-set drops the defaults');
}

# --- 7. install --dry-run 必须被接受 --------------------------------------

{
	# 解析层只要不把 --dry-run 当成「未知选项」就够了；这里不需要真的解依赖，
	# 所以拿一个必然不存在的包触发失败，只断言错误来自包名而不是旗标。
	require Fink::Config;
	Fink::Config->new_with_path('basepath/etc/finx.conf');
	local $SIG{__WARN__} = sub { };	# 测试树里没有 finkinfo，会有一串警告
	eval { Fink::Engine::cmd_install('--dry-run', 'no-such-package-xyzzy'); };
	unlike($@, qr/unknown option/i, 'install accepts --dry-run');
	like($@, qr/no package found|Package requirements/i,
		'and the failure is about the package, not the flag');
}
