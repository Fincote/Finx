# 安装前缀

**唯一规范前缀是 `/opt/finx`。**

这份文档讲三件事：为什么只有一个前缀、代码里该用哪种写法、以及写死了会怎样。

---

## 一、为什么不能有第二个

二进制包**不可重定位**。这不是选择，是 Mach-O 的性质：

- dylib 的 `install_name` 在编译时就被写成绝对路径 `/opt/finx/lib/libfoo.dylib`
- 可执行文件里的 `@rpath` 解析、`-L` 搜索路径同理
- dpkg 的 `var/lib/dpkg/info/*.list` 记的是绝对路径

所以同一个 `.deb` 挪到 `/opt/other` 下跑不起来，除非重新做重定位并重签名 —— 而
那已经不是「换个地方装」，是「重新打一个包」。

Fink 历史上因为要迁就不同 macOS 版本，在 `/sw` 与 `/opt/sw` 之间分叉过。这个分叉
的代价是：每个二进制包都要针对每个前缀各打一份，镜像里的东西翻倍。Finx 取消它。

### 安装器会当场拒绝别的落点

从 `0.1.0-alpha-7c2ae649` 起，`finx-install/install.sh` 的 `--prefix` 只接受
`/opt/finx`，其余在碰磁盘之前就退出（`enforce_prefix_policy`，见
`finx-install/lib/extract.sh`）。

这不是「严谨一点」的问题。安装器对**给它的那个目录**做三件事：

| 步骤 | 落在 `/usr/local` 上会怎样 |
| --- | --- |
| `tar -xzf seed.tar.gz -C <前缀>` | 覆盖所有同名路径 |
| 符号链接围栏判定失败时 | 清空前缀的顶层内容 |
| `fix_permissions` | `chown -R root:wheel <前缀>` |

第二条是我们为了安全加的（半装好的树比没装更危险）。对刚创建的前缀是对的；对
`/usr/local` 就是把 Homebrew 删掉，再由第三步接管。

判定按**物理路径**做，不是字符串：`--prefix=/opt/../usr/local` 与指向
`/usr/local` 的符号链接都会被识别出来。反过来，`/opt/../opt/finx` 归一化之后
确实是 `/opt/finx`，会放行 —— 否则守卫就成了「不许写 `..`」这条与真正意图无关的
规则。

`FINX_TEST` 沙箱里不设这条限制：那里的边界是测试根，前缀本来就在
`$TEST_ROOT/opt/finx`，由 `apply_test_root` 负责判定它没有越界。

---

## 二、代码里怎么写

| 场合 | 写法 |
| --- | --- |
| Perl 模块里 | `$basepath`（`Fink::Config` 导出） |
| 包描述的脚本字段 | `%p` |
| 模板文件（`*.in`） | `@PREFIX@`，由 `setup.sh` 替换 |
| shell 脚本里 | `$PREFIX` 或传参进来的 `$basepath` |

**不要写 `/opt/finx`。** 唯一例外见下一节。

---

## 三、唯一必须硬编码的地方

`perlmod/Fink/Config.pm` 的 `bindist_check_prefix`：

```perl
sub bindist_check_prefix {
    my ($self) = @_;
    my $err = <<ERR;
Downloading packages from the binary distribution is currently only possible
if Fink is installed at '/opt/finx'.
ERR
    return $self->param('Basepath') eq '/opt/finx' ? 0 : $err;
}
```

它的职责就是回答「这个安装能不能用官方二进制包」，而唯一正确的答案是「前缀与
官方构建时逐字相等」。**这个判断必须写死字面量**，否则它就无法判断这件事。

改这一行等于宣告「官方二进制包可以装到别处」，而那在技术上不成立。

---

## 四、写死了会怎样

`Fink::Validation` 会拦。判定规则在 `Validation.pm`：

```perl
our $hardcoded_prefix_re = qr{(?:/opt/finx|/sw)(?:[\s/]|\Z)};
```

注意它**同时认 `/sw`**：那是旧 Fink 的写法，同样不可移植，同样该拦。

检查的字段（`%check_hardcode_fields`）：

```
patchscript  configureparams  compilescript  testscript  installscript
shlibs       preinstscript    postinstscript prermscript postrmscript
debconf      triggers         conffiles     daemonicfile
以及全部 Set* 变量
```

在这些字段里出现 `/opt/finx`、`/sw`、`/opt/sw`，`finx build` 会报不合规。

---

## 五、`%n` / `%v` 只在这些字段里展开

```perl
our %name_version_fields = qw(
    source sourcedirectory sourcerename
    source0 source0extractdir source0rename
    patch
);
```

其他字段里写 `%n` 会原样保留，不会变成包名 —— 这类错误不会报错，只会让脚本拿到
一个字面的 `%n`。改包描述时要留意。

---

## 六、相关文档

- 目录布局与「装完之后 `/opt/finx` 里有什么」：[`Structure.md`](./Structure.md)
- 为什么这样设计：[`TECHNICAL-GUIDE.md`](./TECHNICAL-GUIDE.md)
- 下载源与镜像：[`MIRRORS.md`](./MIRRORS.md)
- 种子按 macOS 大版本出的原因：[`MIRRORS.md`](./MIRRORS.md) 三点六
