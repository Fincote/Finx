#!/usr/bin/perl -w

# 载荷符号链接围栏的单元测试。
#
# 判定全在两个纯函数里（canon_path / parse_deb_listing），所以这里不需要真的
# 装包，也不需要 dpkg-deb —— 一份手写的 `dpkg-deb -c` 文本就够。

use strict;
use Test::More 'no_plan';

BEGIN { use_ok( 'Fink::Links', qw(&canon_path &is_confined &exempt_list
	&parse_deb_listing &offending_in_tree) ) };

use File::Temp qw(tempdir);
use File::Path qw(make_path);

# ---- canon_path：只做字符串处理，不看文件系统 ---------------------------

is(canon_path('/opt/finx'), '/opt/finx', 'a plain absolute path is unchanged');
is(canon_path('/opt/finx/'), '/opt/finx', 'a trailing slash collapses');
is(canon_path('/opt/finx/../evil'), '/opt/evil', 'a .. may climb out');
is(canon_path('/opt/finx/./a//b'), '/opt/finx/a/b', 'dot and empty segments go');
is(canon_path('/'), '/', 'root stays root');
is(canon_path('/opt/finx/..'), '/opt', 'climbing to the parent works');
is(canon_path('/../..'), '/', 'climbing past root stays at root');

# ---- is_confined：按分段比较，不是字符串前缀 ---------------------------

ok(is_confined('/usr/bin/php'), 'an exempt location is confined');
ok(is_confined('/System/Library/Frameworks/AppKit.framework/AppKit'),
	'a deep path under an exempt location');
ok(!is_confined('/usrlocal'), '"/usrlocal" is not "/usr"');
ok(!is_confined('/Users/someone/.ssh/id_rsa'), 'a home directory is not exempt');
ok(!is_confined('/Library/Preferences/x'), '/Library outside Apple/ is not exempt');
like(exempt_list(), qr{/usr/libexec}, 'exempt_list renders the table');

# ---- parse_deb_listing --------------------------------------------------

my $root = '/opt/finx';
my $listing = <<'LISTING';
drwxr-xr-x root/wheel 0 2026-11-02 22:37 ./
drwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib
-rw-r--r-- root/wheel 41 2026-11-02 22:37 ./lib/real.dylib
lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/rel-ok -> real.dylib
lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/rel-ok-up -> ../bin/finx
lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/sys-ok -> /usr/bin/php
lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/dangling-ok -> ./nothing-yet
lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/evil-write -> /usr/local/test/test_write
lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/evil-climb -> ../../../../etc/passwd
lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/evil-home -> /Users/someone/.ssh/id_rsa
lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/evil-dangling -> /opt/nothing-here
lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/spaced name -> /private/var/x
LISTING

my @expected = (
	'lib/evil-climb -> ../../../../etc/passwd',
	'lib/evil-dangling -> /opt/nothing-here',
	'lib/evil-home -> /Users/someone/.ssh/id_rsa',
	'lib/evil-write -> /usr/local/test/test_write',
	'lib/spaced name -> /private/var/x',
);

# 注意不能写 sort parse_deb_listing(...)：Perl 会把它解析成「用这个子程序当
# 比较函数去排序那个列表」，于是什么都没有真正调用。
my @got = parse_deb_listing($listing, $root);
is_deeply([ sort @got ], \@expected,
	'each escaping link is named, and the legitimate ones are spared');

my @got_slash = parse_deb_listing($listing, '/opt/finx/');
is_deeply([ sort @got_slash ], \@expected,
	'a trailing slash on the root still matches');

is_deeply(
	[ parse_deb_listing("lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/x -> /usr/local/t -> y\n", $root) ],
	['lib/x -> /usr/local/t -> y'],
	'splitting on the first arrow keeps an escaping target from hiding behind the last one');

is_deeply(
	[ parse_deb_listing("lrwxr-xr-x root/wheel 0 2026-11-02 22:37 ./lib/x -> b -> c\n", $root) ],
	[],
	'a relative target containing an arrow stays inside and is accepted');

is_deeply([ parse_deb_listing("", $root) ], [], 'an empty listing yields nothing');
is_deeply([ parse_deb_listing("not a listing at all\n", $root) ], [],
	'garbage in the listing is ignored rather than fatal');

# ---- offending_in_tree：走真实文件系统 ----------------------------------

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/root/lib", "$tmp/root/bin");
open(my $fh, '>', "$tmp/root/lib/real") or die $!;
close($fh);
symlink 'real', "$tmp/root/lib/ok" or die $!;
symlink '../bin', "$tmp/root/lib/ok-up" or die $!;
symlink '/usr/bin/php', "$tmp/root/lib/sys" or die $!;
symlink '/usr/local/test/w', "$tmp/root/lib/evil" or die $!;
symlink '../../../../etc/passwd', "$tmp/root/lib/climb" or die $!;

my @tree = offending_in_tree("$tmp/root");
is_deeply([ sort @tree ],
	['lib/climb -> ../../../../etc/passwd', 'lib/evil -> /usr/local/test/w'],
	'offending_in_tree finds both escapes and spares the legitimate links');

# Local Variables:
# mode: perl
# End:
