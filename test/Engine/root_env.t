#!/usr/bin/perl -w

use strict;
use Test::More 'no_plan';

use Fink;
use Fink::Engine;

my @vars = qw/ PERL5LIB
	http_proxy https_proxy ftp_proxy rsync_proxy all_proxy no_proxy
	HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY /;

# 只留下想测的那几个变量，别让跑测试的人自己的代理干扰结果。
sub scrub {
	foreach my $var (@vars) { delete $ENV{$var} }
}

scrub();
is( Fink::Engine::root_env_prefix(), '', 'nothing set, nothing to pass' );

$ENV{PERL5LIB} = '/opt/finx/lib/perl5';
$ENV{https_proxy} = 'http://127.0.0.1:7890';
$ENV{NO_PROXY} = 'localhost,127.0.0.1';
is( Fink::Engine::root_env_prefix(),
	"/usr/bin/env PERL5LIB='/opt/finx/lib/perl5' https_proxy='http://127.0.0.1:7890' NO_PROXY='localhost,127.0.0.1'",
	'lib path and both proxy spellings survive a sudo re-exec' );

# 代理口令里带单引号不能把命令拆开。
$ENV{ALL_PROXY} = "socks5://alice:o'brien\@127.0.0.1:1080";
my $q = Fink::Engine::root_env_prefix();
like( $q, qr/ALL_PROXY='socks5:\/\/alice:o'\\''brien\@127\.0\.0\.1:1080'/,
	'single quote in a proxy password is escaped, not dropped' );

# 这些变量名必须被送过去，回归时会直接看到少了哪一个。
my %passed = map { /^([A-Za-z0-9_]+)=/ ? ($1 => 1) : () } split /\s+/, $q;
ok( $passed{https_proxy}, 'https_proxy passed' );
ok( $passed{ALL_PROXY}, 'uppercase spelling passed too' );
ok( $passed{PERL5LIB}, 'PERL5LIB passed' );
ok( !$passed{CDPATH}, 'unrelated variables stay cleaned' );

scrub();
