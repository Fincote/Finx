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

Fink::Domains - the single source of every outward-facing address

=head1 SYNOPSIS

  use Fink::Domains qw(&domain &is_custom &redact_url);

  my $base = domain('bottle');          # environment first, then built-in default
  my $url  = "$base/$pkg/$file";
  print redact_url($url);               # redact before printing or logging

=head1 DESCRIPTION

One list of "where to fetch from", so no other module writes its own literals.

Why this module exists: the addresses used to live in three places -- the
C<CustomMirror> field in C<.info> files, string literals in the code, and a pile
of "one-line files as CNAMEs" under C<lib/finx/mirror/> and C<lib/finx/URL/>.
The quietest way for that indirection to die is data going stale while the code
was fixed, so the B<old address wins>: the fallback in C<SelfUpdate/CVS.pm> had
long said C<finx.cvs.sourceforge.net>, while C<URL/cvs-repository> still held the
2018 value C<fink.cvs.sourceforge.net>; the file existed, so the file won, and
nobody noticed.

So there is exactly one rule: B<environment variable, then built-in default, no
third source>.

=head2 Variables

  FINX_API_DOMAIN         package description tree (infosource)
  FINX_DEB_DOMAIN         prebuilt .deb packages (one release per package)
  FINX_SOURCE_DOMAIN      finx's own source archive
  FINX_SOURCECODE_DOMAIN  upstream source pool (what CustomMirror points at)
  FINX_SELFUPDATE_DOMAIN  self-update data

  FINX_MIRROR_DOMAIN      a base: overrides all of the above as <base>/<kind>

All of them may carry credentials (C<< ******host/path >>), because mirrors often
need an account. C<finx mirror> prints them with passwords masked by default.

The installer (C<finx-install/install.sh>) has its own set:
C<FINX_INDEX_DOMAIN> / C<FINX_SEED_DOMAIN> / C<FINX_SEED_BASE>. Those are the
addresses used before bootstrap, and must not be confused with these.

C<FINX_MIRROR_DOMAIN> is for self-hosted mirrors that follow MacWave's layout,
where one product puts all of its kinds side by side
(C<https://mirror.example.top/Finx/bottle>, C<.../Finx/sourcecode>, ...). Fill in
the base only; a per-kind variable still wins.

Escalation: C<finx install> / C<fetch> / C<build> re-execute themselves as root,
and these variables are forwarded across sudo by
C<Fink::Engine::root_env_prefix()>. Add a new variable here and you must add it
to C<@ROOT_ENV_VARS> in C<Engine.pm> too, or it silently disappears from every
command that needs root.

=head1 Validation

The value is spliced into URLs, written into error messages, and could be used
by a shell as an argument, so refusing early is better than failing late:

=over 4

=item * only C<https://> and C<file://>; plain C<http://> is limited to loopback (offline tests)

=item * whitespace, control characters, quotes, C<$> and backticks are refused

=item * trailing slashes are stripped, so building a path never has to care

=back

=head1 Why not use JSON

C<finx mirror --json> is hand-written: Fink has to run on 5.8, and C<JSON::PP>
only entered core in 5.14. The table has five fixed fields, so escaping two
characters is enough.

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

=head1 Functions

=over 4

=item domain(KIND)

Its own environment variable, then C<< <base>/<KIND> >> derived from
C<FINX_MIRROR_DOMAIN>, then the built-in default. Returns the empty string when
all three are empty, which means "this kind has no fixed address yet". Trailing
slashes are stripped and the value is validated before it is returned.

=item is_custom(KIND)

Whether the user pointed KIND somewhere explicit -- either through its own
variable or through the base.

=item builtin_default(KIND)

The built-in default itself, unaffected by the environment. After a user
override, callers still need it to recognise "that official string" and replace
it in place.

=item url_for(KIND, PATH)

C<domain(KIND)/PATH>. Degrades as needed when the domain or the path is empty.

=item rows(SHOW_PASSWORD, HIDE_USER)

The rows behind C<finx mirror>: name, variable, source (env / base / default /
unset), whether it carries credentials, and the masked value.

=item redact_url(URL)

Rewrites C<user:pass@> as C<user:***@> and leaves the rest alone. Credentials are
only recognised inside the authority segment.

=item masked_url(URL, SHOW_PASSWORD, HIDE_USER)

The mask used for display; the password becomes a fixed six asterisks.

=back

=cut
