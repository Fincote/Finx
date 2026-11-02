PREFIX=/opt/finx
ARCHITECTURE=x86_64
VERSION=`cat VERSION`
TEST_BASEPATH=$(PWD)/t/basepath
TESTS=.

all:
	@echo    "usage: $(MAKE) <target>"
	@echo    ""
	@echo -e "\tbootstrap   install a fresh finx installation"
	@echo -e "\t            PREFIX can be set, defaults to /opt/finx"   
	@echo -e "              ARCHITECTURE can also be set, defaults to x86_64"   
	@echo -e "\tinstall     install to an existing finx installation"
	@echo -e "\ttest        perform tests on the finx code"
	@echo -e "\tstructure   cross-check git, MANIFEST and what install.sh really installs"
	@echo -e "\tsources_check  verify the bundled source tarballs still match their checksums"
	@echo -e "\tformat      check indentation of all Perl and shell sources"
	@echo -e "\tclean       remove all extraneous files"
	@echo    ""

bootstrap: test
	./bootstrap $(PREFIX)

install:
	./inject.pl $(PREFIX)

test_setup:
	./setup.sh $(TEST_BASEPATH) $(ARCHITECTURE)

manifest_check:
	perl -MExtUtils::Manifest=fullcheck -e 'my($$missing, $$extra) = fullcheck;exit (@$$missing || @$$extra)'

# 三份清单（git、MANIFEST、install.sh 实际装出来的东西）的交叉校验。
# 挂进 test 的理由与 manifest_check 相同：不一致会直接让安装缺文件，
# 属于正确性问题，不是格式洁癖。完整背景见 scripts/structure_test.sh 的注释。
structure:
	FINX_ARCH="$(ARCHITECTURE)" ./scripts/structure_test.sh

# 内置源码包的 tar 必须与 .info 里登记的 Source-MD5 一致。
# 换 tar 版本、或改了 base-files/ 里的文件却忘了重新登记，这里当场失败；
# 否则要等 bootstrap 跑到一半，才发现 Fink 在问「校验和不符」。
sources_check:
	./base-files/pack.sh --check

# 所有 Perl 文件都必须能在系统 Perl 5 下编译。
# 顺带挡住 Raku（Perl 6）语法：那是一门不同的语言，多数写法会直接语法失败，
# 少数会在 Perl 5 里解析成别的意思 —— 后者不报错，最麻烦。
perl_check:
	./scripts/perl_check.sh

# 种子打包器与安装器的往返验证。make_seed.sh 决定所有人下载到的是什么，
# 两边任何一边走偏都只会安静地装出一个坏前缀，所以要真跑一遍。
#
# 故意**不**挂进 test：它要跑 finx-install/install.sh，而 MANIFEST.SKIP 把
# finx-install/ 排除在载荷之外 —— bootstrap 在载荷树里跑 make test，那里没有
# 这个目录。挂进去会让每一次自举都卡在「找不到 install.sh」。
seed_test:
	./scripts/seed_test.sh

# 在「只有 MANIFEST 文件的树」里跑一遍 make test —— 那就是 finx 包自己的
# CompileScript 执行时的环境（见 finx.info.in）。故意不挂进 test：那等于在
# 载荷树里递归调用自己。
payload_test:
	FINX_ARCH="$(ARCHITECTURE)" ./scripts/payload_test.sh

# 缩进检查。故意不挂进 test：bootstrap 会跑 make test，而格式瑕疵不该拦住安装。
# Perl 用 tab、shell 用 4 空格，规则与例外见 scripts/format_check.pl 的注释。
format:
	./scripts/format_check.pl

# perl_check 排在 test_setup 之后：它需要 setup.sh 生成的
# perlmod/Fink/FinkVersion.pm，否则每个模块都会报「找不到 Fink::FinkVersion」，
# 看着像代码坏了。
test: manifest_check structure sources_check test_setup perl_check
	@# must test with same perl binary as the one to be used to run finx
	@# (which also must be coded into t/Services/execute_nonroot_okay.t)
	cd t && ./testmore.pl && find ${TESTS} -name '*.t' | sort | PREFIX="$(PREFIX)" xargs /usr/bin/perl -I`pwd`/../perlmod -MTest::Harness -e 'runtests(@ARGV)'

# remove various generated files
clean:
	rm -f compiler_wrapper 
	rm -f compiler_wrapper-10.7
	rm -f compiler_wrapper-10.9
	rm -f config*
	rm -f finx
	rm -f finx-dpkg-status-cleanup
	rm -f finx-virtual-pkgs
	rm -f finx-virtual-pkgs-bootstrap
	rm -f finx-instscripts
	rm -f finx-scanpackages
	rm -f finx.8
	rm -f finx.conf.5
	rm -f pathsetup.command
	rm -f pathsetup.sh
	rm -f postinstall.pl
	rm -f shlibs.default
	rm -f dpkg-lockwait
	rm -f apt-get-lockwait
	rm -f g++-wrapper-3.3
	rm -f g++-wrapper-4.0
	rm -f perlmod/Fink.pm
	rm -f perlmod/Fink/FinkVersion.pm
	rm -f t/basepath/etc/apt/sources.list
	rm -f t/basepath/etc/apt/sources.list.finkbak

# maybe we should clean or ./setup.sh before this, to eliminate dups?
podcheck:
	@find . -name '.git' -prune -o \! -name '.#*' -type f -print | \
		xargs grep -l '[=]head' | xargs podchecker

.PHONY: all bootstrap install test test_setup manifest_check format clean podcheck

.SUFFIXES:

# vim: ts=4 sw=4 noet
