#!/usr/bin/perl -w

use strict;
use Test::More 'no_plan';
use File::Copy;
use File::Temp qw(tempdir);

use Fink::Config;

# root 下 chmod 拦不住写，这些断言就没有意义了。
if ($> == 0) {
	SKIP: { skip "running as root", 4; }
	exit 0;
}

my $Config_File = 'basepath/etc/finx.conf.copy';
copy('basepath/etc/finx.conf', $Config_File) or die "copy: $!";
END { unlink $Config_File }

my $config = Fink::Config->new_with_path($Config_File);

ok( $config->can_save, 'writable config can be saved' );

# 普通用户读 root 装的配置就是这种状态：文件读得到，目录写不进。
my $ro_dir = tempdir(CLEANUP => 1);
copy('basepath/etc/finx.conf', "$ro_dir/finx.conf") or die "copy: $!";
chmod 0555, $ro_dir;
my $ro = Fink::Config->new_with_path("$ro_dir/finx.conf");
ok( !$ro->can_save, 'config in a read-only dir cannot be saved' );

ok( !bless({ _path => '' }, 'Fink::Config')->can_save,
	'object without a path cannot be saved' );

# save() 自己仍然该硬失败：真正的写入错误不能被吞掉。
$ro->set_param('wiffle', 42);
eval { $ro->save; 1 };
ok( $@, 'save() still dies on an unwritable config' );
