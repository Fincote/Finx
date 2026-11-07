# -*- mode: Perl; tab-width: 4; -*-
#
# Fink::Domains - 所有对外地址的唯一来源
#
# Fink - a package manager that downloads source and installs it
# Copyright (c) 2001 Christoph Pfisterer
# Copyright (c) 2001-2026 The Fink Package Manager Team
# Copyright (c) 2026 Sha0huaZhang <zsh@finx.sh>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
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

package Fink::Domains;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(domain is_custom url_for rows redact_url masked_url
			split_userinfo kinds env_name description builtin_default);

=head1 NAME

Fink::Domains - 所有对外地址的唯一来源

=head1 SYNOPSIS

  use Fink::Domains qw(&domain &is_custom &redact_url);

  my $base = domain('bottle');          # 环境变量优先，其次内置默认
  my $url  = "$base/$pkg/$file";
  print redact_url($url);               # 打印/写日志前先脱敏

=head1 DESCRIPTION

一份「从哪儿取」的清单，其它模块不再各写各的字面量。

为什么要有这个模块：以前地址散在三处 —— `.info` 的 `CustomMirror`、代码里的
字符串、以及 `lib/finx/mirror/` 与 `lib/finx/URL/` 下一堆「单行文件当 CNAME」
的数据。那种间接层最安静的死法是数据过期而代码已经改对，于是**旧地址赢**：
`SelfUpdate/CVS.pm` 的兜底早就写成 `finx.cvs.sourceforge.net`，而
`URL/cvs-repository` 里仍是 2018 年的 `fink.cvs.sourceforge.net`，文件在就以
文件为准，没人发现。

所以规则只有一条：**环境变量 → 内置默认，没有第三个来源**。

=head2 变量

  FINX_API_DOMAIN         包描述树（infosource）
  FINX_DEB_DOMAIN         预编译 .deb（Bottle 式：一包一 Release）
  FINX_SOURCE_DOMAIN      finx 自身源码归档
  FINX_SOURCECODE_DOMAIN  上游源码池（CustomMirror 指向的那批）
  FINX_SELFUPDATE_DOMAIN  自更新数据

  FINX_MIRROR_DOMAIN      基址：一次覆盖上面全部（地址是基址后面接 kind）

全部可带凭据（C<< https://user:pass@host/path >>），因为镜像站常需要账号。
`finx mirror` 会打印它们，密码默认打码。

安装器那一层（`finx-install/install.sh`）另有一组 `FINX_INDEX_DOMAIN` /
`FINX_SEED_DOMAIN` / `FINX_SEED_BASE`，那是 bootstrap 之前取种子的地址，
与这里的别混。

`FINX_MIRROR_DOMAIN` 是给自建镜像用的：镜像站按 MacWave 的布局，把一个产品的
各类内容放在同一层目录下（`https://mirror.example.top/Finx/bottle`、
`.../Finx/sourcecode` …），所以只填基址就够，单个 kind 的变量仍然优先。

提权那一段：`finx install` / `fetch` / `build` 会以 root 重新执行自己，上面这些
变量由 `Fink::Engine::root_env_prefix()` 显式转发过 sudo。往本模块加新变量时
必须同步 `@ROOT_ENV_VARS`（`Engine.pm`），否则它们在需要 root 的命令里静默失效。

=head1 校验

值会被拼进 URL、写进错误信息，也可能被 shell 当参数用，所以宁可拒绝得早：

=over 4

=item * 只接受 C<https://> 与 C<file://>；明文 C<http://> 仅限回环地址（离线测试）

=item * 空白、控制字符、引号、C<$> 与反引号一律不收

=item * 末尾斜杠一律去掉，拼路径时不用再关心有没有写

=back

=head1 为什么不用 JSON

`finx mirror --json` 是手写的：Fink 要能跑在 5.8 上，而 `JSON::PP` 是 5.14 才
进核心的。表里只有五个固定字段，转义两个字符就够。

=cut

# 顺序即 `finx mirror` 的打印顺序，也是 --raw 的导出顺序
our @KINDS = qw(api bottle core sourcecode selfupdate);

my %ENV_NAME = (
	api        => 'FINX_API_DOMAIN',
	bottle     => 'FINX_DEB_DOMAIN',
	core       => 'FINX_SOURCE_DOMAIN',
	sourcecode => 'FINX_SOURCECODE_DOMAIN',
	selfupdate => 'FINX_SELFUPDATE_DOMAIN',
);

my %DESCRIPTION = (
	api        => 'package description tree',
	bottle     => 'prebuilt .deb packages',
	core       => "finx's own source archive",
	sourcecode => 'upstream source pool',
	selfupdate => 'self-update data',
);

# 一个基址覆盖全部 kind。镜像站按 MacWave 的布局把每类内容放在 <基址>/<kind>
# 下面，所以自建镜像只填这一条；单独某个 kind 的变量仍然优先。
#
# 注意它是「基址」而不是某个 kind 的环境变量：它自己不会被拼进 URL，
# 只参与派生，所以校验失败时报的变量名也必须是它。
our $BASE_ENV = 'FINX_MIRROR_DOMAIN';

# 空串的含义是「这块内容还没有搬到固定地址」，不是「配错了」。调用方拿到空串
# 就继续用包描述里的字段（.info 的 CustomMirror），而不是拼出一个坏地址。
my %DEFAULTS = (
	api        => '',
	bottle     => 'https://github.com/Fincote/debs/releases/download',
	core       => 'https://codeload.github.com/Fincote/Finx',
	sourcecode => 'https://github.com/Fincote/Finx-source/releases/download/src-1',
	selfupdate => '',
);

my @LOOPBACK_HOSTS = ('127.0.0.1', 'localhost', '::1', '[::1]');

# 打码用固定六个星号：与真实长度无关，否则星号个数会泄露密码长度。
our $MASK = '******';

sub kinds { return @KINDS }
sub env_name { return $ENV_NAME{$_[0]} }
sub description { return $DESCRIPTION{$_[0]} }

# 把值里的 userinfo 拆出来，返回 (不含凭据的基址, 用户名, 密码)。
# 没有 userinfo 时返回 (原值, undef, undef)，调用方据此判断「要不要脱敏」。
#
# 只在 authority 段里找 @：path 里的 @ 是合法文件名（ncdu@1.22-1...deb），
# 拿整条 URL 去找最后一个 @ 会把包名当成密码位置。
sub split_userinfo {
	my $value = shift;
	return ($value, undef, undef) unless defined $value && length $value;

	my ($scheme, $rest) = $value =~ m{^([^:]+)://(.*)$}s;
	return ($value, undef, undef) unless defined $rest;

	my ($authority, $path) = split m{/}, $rest, 2;
	return ($value, undef, undef) unless defined $authority && $authority =~ /\@/;

	my ($userinfo, $host) = $authority =~ m{^(.*)\@([^\@]*)$}s;
	return ($value, undef, undef) unless defined $userinfo;

	my ($user, $colon, $password) = $userinfo =~ /^([^:]*)(:?)(.*)$/s;
	$password = '' unless defined $password && length $colon;
	my $base = defined $path ? "$scheme://$host/$path" : "$scheme://$host";
	return ($base, $user, $password);
}

sub _with_userinfo {
	my ($base, $user, $password) = @_;
	my ($scheme, $rest) = $base =~ m{^([^:]+)://(.*)$}s;
	return $base unless defined $rest;
	return "$scheme://$user:$password\@" . $rest;
}

# 给 `finx mirror` 用的展示值：密码打码，可选连带用户名一起打码。
sub masked_url {
	my ($value, $show_password, $hide_user) = @_;
	my ($base, $user, $password) = split_userinfo($value);
	return $value unless defined $user;
	my $shown_user = $hide_user ? $MASK : $user;
	my $shown_password = $show_password ? $password : $MASK;
	return _with_userinfo($base, $shown_user, $shown_password);
}

# 写日志、拼错误信息之前一律过一遍 —— 那些输出会被贴进 issue。
sub redact_url {
	my $url = shift;
	return $url unless defined $url && length $url;
	my ($base, $user, $password) = split_userinfo($url);
	return $url unless defined $user;
	my $masked = length $password ? "$user:***" : '***';
	my ($scheme, $rest) = $base =~ m{^([^:]+)://(.*)$}s;
	return $url unless defined $rest;
	return "$scheme://$masked\@" . $rest;
}

# 值会被拼进 URL、写进错误信息，也可能被 shell 当参数用，所以宁可拒绝得早。
sub _validate {
	my ($kind, $value, $name) = @_;
	$name = $ENV_NAME{$kind} unless defined $name;

	for my $bad (" ", "\t", "\n", "\r", "\"", "'", "`", '$', "\\") {
		die "$name contains a control or quoting character. "
			. "It should look like https://mirror.example.com/finx "
			. "(" . $DESCRIPTION{$kind} . ")\n"
			if index($value, $bad) >= 0;
	}

	my ($scheme, $rest) = $value =~ m{^([^:]+)://(.+)$}s;
	die "$name has no scheme: $value\n" unless defined $rest;

	$scheme = lc $scheme;
	return $value if $scheme eq 'https' || $scheme eq 'file';

	if ($scheme eq 'http') {
		# 明文 http 只给本机镜像（测试、离线环境）。先剥掉 user:pass@ 再看主机
		# —— 否则带凭据时拿到的是用户名。
		my ($authority) = $rest =~ m{^([^/]*)}s;
		$authority =~ s/^.*\@//;
		my ($host) = $authority =~ /^(\[[^\]]*\]|[^:]*)/;
		$host = '' unless defined $host;
		for my $ok (@LOOPBACK_HOSTS) {
			return $value if $host eq $ok;
		}
		die "$name only accepts plain HTTP for a loopback mirror: $value\n";
	}

	die "$name has an unsupported scheme ($scheme): $value\n";
}

# 解析一个 kind，返回 (值, 来源)。来源是 env / base / default / unset。
#
# 顺序即优先级。base 那条要过校验，因为基址本身可能是坏的；报错指向
# FINX_MIRROR_DOMAIN，而不是某个 kind 的变量。
sub _resolve {
	my $kind = shift;

	my $own = _strip_slashes(_trim($ENV{$ENV_NAME{$kind}}));
	return ($own, 'env') if length $own;

	my $base = _strip_slashes(_trim($ENV{$BASE_ENV}));
	if (length $base) {
		my $value = "$base/$kind";
		_validate($kind, $value, $BASE_ENV);
		return ($value, 'base');
	}

	my $default = $DEFAULTS{$kind};
	return ($default, 'default') if defined $default && length $default;
	return ('', 'unset');
}

sub _trim {
	my $value = shift;
	$value = '' unless defined $value;
	$value =~ s/^\s+//;
	$value =~ s/\s+$//;
	return $value;
}

# 末尾斜杠一律去掉，拼路径时不用再关心有没有写。
sub _strip_slashes {
	my $value = shift;
	1 while $value =~ s{/+$}{};
	return $value;
}

# 解析一个地址：单独的环境变量优先，其次 FINX_MIRROR_DOMAIN 派生的
# <基址>/<kind>，最后内置默认。三处都为空时返回空串。
#
# 校验失败直接 die：这个函数会在任何下载之前被调用，早失败比在下到一半时
# 才发现地址是坏的强。
sub domain {
	my $kind = shift;
	return '' unless defined $kind && exists $ENV_NAME{$kind};

	my ($value, $source) = _resolve($kind);
	return '' unless length $value;

	# base 那条在 _resolve 里已经校验过：派生出来的地址不该再报一次，
	# 否则同一条错误会指向两个变量名。
	_validate($kind, $value, $ENV_NAME{$kind}) unless $source eq 'base';
	return _strip_slashes($value);
}

# 用户是否显式指过这个 kind —— 无论是它自己的变量，还是通过基址派生。
# 镜像站与官方站的能力不一定相同，调用方要靠它区分「用户指的」与「内置的」。
sub is_custom {
	my $kind = shift;
	return 0 unless defined $kind && exists $ENV_NAME{$kind};
	my ($value, $source) = _resolve($kind);
	return ($source eq 'env' || $source eq 'base') ? 1 : 0;
}

# 内置默认值本身。调用方在用户覆盖之后仍需知道「官方地址长什么样」，
# 例如把 .info 里那一串原样换掉，而不是整段丢弃。
sub builtin_default {
	my $kind = shift;
	return '' unless defined $kind && exists $DEFAULTS{$kind};
	my $default = $DEFAULTS{$kind};
	return defined $default ? $default : '';
}

# 拼一个地址。域名之后是一条纯文件路径，镜像站 rsync 出同一棵树即可。
sub url_for {
	my ($kind, $path) = @_;
	my $base = domain($kind);
	return undef unless length $base;
	$path = '' unless defined $path;
	$path =~ s{^/+}{};
	return length $path ? "$base/$path" : $base;
}

# `finx mirror` 的数据源。每一行都是「该打印成什么」，渲染层不必再判断脱敏。
sub rows {
	my ($show_password, $hide_user) = @_;
	my @rows;

	for my $kind (@KINDS) {
		my $value = domain($kind);
		my (undef, $source) = _resolve($kind);
		my ($base, $user) = split_userinfo($value);

		push @rows, {
			name          => $kind,
			env           => $ENV_NAME{$kind},
			source        => $source,
			requires_auth => defined $user ? 1 : 0,
			user          => defined $user ? ($hide_user ? $MASK : $user) : undef,
			value         => length $value
				? masked_url($value, $show_password, $hide_user)
				: '',
		};
	}

	return @rows;
}

1;

__END__

=head1 函数

=over 4

=item domain(KIND)

单独的环境变量 → `FINX_MIRROR_DOMAIN` 派生的 C<< <基址>/<KIND> >> → 内置默认。
都为空时返回空串，表示「这块内容还没有固定地址」。返回前会去掉末尾斜杠并校验。

=item is_custom(KIND)

用户是否显式指过 KIND —— 无论是它自己的变量，还是通过基址派生。

=item builtin_default(KIND)

内置默认值本身，不受环境变量影响。用户覆盖之后，调用方仍要靠它认出
「原来那一串官方地址」并就地替换。

=item url_for(KIND, PATH)

C<domain(KIND)/PATH>。域名或路径为空时按需要退化。

=item rows(SHOW_PASSWORD, HIDE_USER)

给 `finx mirror` 用的行：名称、变量、来源（env / base / default / unset）、
是否带凭据、打码后的值。

=item redact_url(URL)

把 C<user:pass@> 换成 C<user:***@>，其余原样。只在 authority 段里识别凭据。

=item masked_url(URL, SHOW_PASSWORD, HIDE_USER)

展示用的打码，密码固定六个星号。

=back

=cut
