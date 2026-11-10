# -*- mode: Perl; tab-width: 4; -*-
#
# Fink::Help - 把选项表和 helpformat 模板渲染成 --help 文本
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

package Fink::Help;

use strict;
use warnings;

use Fink::CLI qw(&word_wrap &get_term_width);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(&color_enabled &paint &paint_label &option_usage
					&align_option_text &option_help &expand_help &new_option
					&edit_distance &nearest_name
					&unknown_command_message &unknown_option_message);

=head1 NAME

Fink::Help - renders `finx <command> --help`

=head1 SYNOPSIS

  use Fink::Services qw(&get_options);       # this is all callers normally touch

  get_options('install', [
      [ 'dry-run|n' => \$dryrun, 'Print what would be done.' ],
  ], \@_, helpformat => "%intro{[options]}\n%all{}\n");

=head1 DESCRIPTION

Parsing the option table (Getopt::Long, validation, exiting on error) stays in
C<Fink::Services::get_options>. This module only B<turns the parsed result into
text>: wrapping, alignment, and colouring by role.

It is a separate module because the layout rules (column width for C<%align>, the
C<word_wrap> width, the padding that keeps indentation outside the colour) have
nothing to do with anything else, and changing one of them inside
C<Fink::Services> means scrolling past two thousand lines. MacWave's
C<lib/help.py> occupies the same position.

=head2 The helpformat template

The C<helpformat> given to C<get_options> is a string supporting these constructs:

  %opts{opt1,opt2,...}  Prints the default usage and description for the
                        given options 'opt1', 'opt2', etc.

  %all{}                Prints the default usage and description for all
                        options.

  %align{opt,desc}      Prints the option 'opt' and its description 'desc',
                        aligned with other options.

  %align{opt,desc,optspace}
                        Prints the option 'opt' and its description 'desc',
                        aligned such that the option part takes up a width
                        of optspace characters.

  %intro{ex,...}        Print a help introduction, with 'ex' as a very short
                        generic example of calling this command, such as:
                        '[options] [packages]'. With multiple examples, will
                        print one per line.

  %%                    Print a literal percent character.

Percent can also be used to escape comma and curly brackets inside an
expansion.

The template carries no C<${name}> colour markers: colour is B<produced as escape
codes right here> (see C<paint>), so the text itself stays plain and any tool
that treats it literally is not confused by escape codes. Whether to colour at
all is decided in one place, C<Fink::Color::enabled>.

=cut

# 颜色的定义与开关都在 Fink::Color；这里只是两个薄包装，因为帮助渲染是按
# 「角色」（section/prog/flag/value）取色的，而不是按名字。

=over 4

=item color_enabled

  my $bool = color_enabled();

Same as C<Fink::Color::enabled>. It is exported separately because template
handling needs it to decide whether a flush-left section header gets the
C<section> colour.

=back

=cut
sub color_enabled {
	require Fink::Color;
	return Fink::Color::enabled();
}

=over 4

=item paint

  my $text = paint($text, $role);

Colours the whole string by role. C<$role> is a semantic alias from C<%PALETTE>
(C<section>, C<prog>, C<flag>, C<value>, C<bold>). Returns the text unchanged
when colour is off.

=back

=cut
sub paint {
	my ($text, $role) = @_;
	require Fink::Color;
	return Fink::Color::paint($text, $role);
}

=over 4

=item paint_label

  my $text = paint_label($text, $role, $value);

Colours a "label plus value" string: the label with C<$role>, the trailing value
placeholder (the C<TREES> in C<--trees=TREES>) with the C<value> colour.

Indentation is deliberately kept outside the colour: when escape codes wrap the
spaces, some terminals drag extra spaces along on copy and paste.

=back

=cut
sub paint_label {
	my ($text, $role, $value) = @_;
	return $text if $text =~ /^\s*$/;
	return $text if !color_enabled();

	my ($indent, $body) = $text =~ /^(\s*)(.*)$/;
	if (defined $value && length $value) {
		my $quoted = quotemeta $value;
		if ($body =~ /^(.*?)([=\s])($quoted)$/) {
			return $indent . paint($1, $role) . $2 . paint($3, 'value');
		}
	}
	return $indent . paint($body, $role);
}

=over 4

=item option_usage

  my $text = option_usage($optitem);

Turns a Getopt specification into the form a person reads: C<-f, --full=VALUE>.
A short option takes its value after a space, a long one after an equals sign.

=back

=cut
sub option_usage {
	my $opt = shift;

	# Try each way to specify option (eg: -f, --full)
	my @alts = sort { length($a) <=> length($b) } @{$opt->{names}};
	foreach my $alt (@alts) {
		if (length($alt) == 1) {
			$alt = "-$alt";
			$alt .= " $opt->{value}" if defined $opt->{value};
		} else {
			$alt = "--$alt";
			$alt .= "=$opt->{value}" if defined $opt->{value};
		}
	}
	return join ', ', @alts;
}

=over 4

=item align_option_text

  my $text = align_option_text($usage, $desc, $optlen, $role, $value);

Lays out the usage and the description of one option in two columns, wrapping the
description to the terminal width.

C<$role> decides the label's colour (C<cmd> or C<flag>); C<$value> is the name of
the flag's value placeholder.

Padding must be computed from the B<uncoloured> length: escape codes add five or
six characters to C<length()> and the columns would no longer line up.

=back

=cut
sub align_option_text {
	my ($opttxt, $desctxt, $optlen, $role, $value) = @_;
	my $ret = "";

	# Word wrap things
	my $desclen; # Ensure there's a reasonable size
	for my $width (get_term_width(), 80) {
		$desclen = $width - $optlen - 3;
		last if $desclen > 5;
	}

	my @optlines = word_wrap $opttxt, $optlen, '  ', '    ';
	my @desclines = map { word_wrap $_, $desclen }
		split /\n/, $desctxt; # Respect newlines

	# Add 'em to the message by pairs
	my $first = 1;
	while (1) {
		my $optpart = shift @optlines;
		my $descpart = shift @desclines;
		last unless defined $optpart || defined $descpart;
		$descpart = '' unless defined $descpart;

		my $midpart = $first ? ' - ' : '   ';
		$first = 0 if $first;

		if (!defined $optpart) {
			$ret .= (' ' x $optlen) . $midpart . $descpart . "\n";
			next;
		}

		my $pad = $optlen - length($optpart);
		$pad = 0 if $pad < 0;
		$ret .= paint_label($optpart, $role, $value) . (' ' x $pad)
			. $midpart . $descpart . "\n";
	}

	return $ret;
}

=over 4

=item option_help

  my $text = option_help($optitem, $optlen);

The full help for one option, possibly several lines. An option with the C<!>
modifier (such as C<use-binary-dist!>) also produces a C<--no-...> entry.

=back

=cut
sub option_help {
	my ($opt, $optlen) = @_;
	my @realopts;
	$DB::single = 1 if grep { $_ eq 'use-binary-dist' } @{$opt->{names}};
	if ($opt->{modifiers} =~ /!/) {
		require Storable;
		my $negopt = Storable::dclone($opt);
		$negopt->{names} = [
			map { length($_) > 1 ? "no-$_" : () } @{$opt->{names}}
		];
		$negopt->{help} = 'Opposite of --'.$opt->{names}->[0];
		@realopts = ($opt, $negopt);
	} else {
		@realopts = $opt;
	}

	my $text = '';
	for my $ropt (@realopts) {
		my $usage = option_usage($ropt);
		$text .= align_option_text($usage, $ropt->{help}, $optlen,
			'flag', $ropt->{value});
	}
	return $text;
}

=over 4

=item new_option

  my $opthash = new_option(@optarray);

Turns one option entry (C<['spec' => \$var, 'help text', 'VALUE']>) into the
internal hash: C<spec/names/modifiers/dest/help/value>.

=back

=cut
sub new_option {
	my $opthash;
	@$opthash{qw(spec dest help value)} = @_;
	$opthash->{spec} =~ /^([\w-]+(\|[\w-]+)*)(.*)$/
		or die "Bad option specification: $opthash->{spec}\n";
	$opthash->{names} = [ split /\|/, $1 ];
	$opthash->{modifiers} = $3;
	return $opthash;
}

=over 4

=item expand_help

  my $text = expand_help($command, $optionlist, $helpformat, $optlen);

Expands the C<helpformat> template and returns the whole block of help text. The
caller prints it (C<Fink::Services::get_options> uses a plain C<print>, not
C<print_breaking>).

The last step colours flush-left lines that end in a colon (C<Common commands:>)
as C<section>: those are ordinary text inside the template, so there is nowhere
else to hook into. It requires flush-left, so an indented description line is
never caught by mistake.

=back

=cut
sub expand_help {
	my ($command, $options, $helpformat, $optlen) = @_;

	# Option table
	my %opts;
	foreach my $opt (@$options) {
		my @names = @{$opt->{names}};
		@opts{@names} = ($opt) x scalar(@names);
	}

	# Expansion table
	my %exp = (
		all => sub {
			"Options:\n" . join '', map { option_help($_, $optlen) }
				@$options;
		},
		opts => sub {
			if (my @missing_opts = grep {!exists $opts{$_}} @_) {
				die "Options (@missing_opts) from \%opts{@_} not defined in option list ("
					. (join ' ', keys %opts) . ")\n";
			}
			chomp (my $ret = join '', map { option_help($_, $optlen) }
				@opts{@_} );
			$ret;
		},
		align	=> sub {
			# %align 自带第三参数 optspace（Config.pm 传 $comlen），没给才用默认宽度。
			# 所以不能写成 align_option_text(@_, $optlen, 'cmd')：那会多顶一位，
			# 把全局 optwidth 当成 optspace、把 'cmd' 当成值占位符。
			my ($otxt, $dtxt, $ospace) = @_;
			$ospace = $optlen unless defined $ospace;
			chomp (my $ret = align_option_text($otxt, $dtxt, $ospace, 'cmd'));
			$ret
		},
		intro	=> sub {
			my $first = shift;
			require Fink::FinkVersion;
			my $prog = 'finx';
			my $usage = paint('Usage:', 'section') . ' '
				. paint($prog, 'prog') . $command;
			paint('Finx ' . Fink::FinkVersion::fink_version(), 'bold') . "\n\n" .
				$usage . " $first\n" .
				join '', map { '       ' . paint($prog, 'prog')
					. $command . " $_\n" } @_;
		},
	);

	# Do the format
	$helpformat =~ s"(?<!\%)((?:\%\%)*)\%(\w+)\{(|.*?[^%])\}"
		return $& unless exists $exp{$2};
		my @args = map { s/(?<!\%)((?:\%\%)*)%([{},])/$1$2/g; $_ }
			split /(?<!%),/, $3;
		$1 . &{$exp{$2}}(@args);
	"ge;
# " <-- preceding s using " as delim confuses emacs syntax-highlight
	$helpformat =~ s/%%/%/g;

	# 节标题统一上色。放在最后一步：它们是模板里的普通文本（`Common commands:`
	# 这类顶格、以冒号结尾的行），没有别的地方可以挂钩。限定顶格，所以缩进的
	# 描述行不会被误伤。
	if (color_enabled()) {
		$helpformat =~ s{^(\S[^\n:]*):$}{paint("$1:", 'section')}gme;
	}

	return $helpformat;
}

# ---------------------------------------------------------------------------
# 打错命令 / 打错旗标时的提示
# ---------------------------------------------------------------------------
#
# 形状照 MacWave 的 lib/help.py（print_error_help）：先回显**用户真实输入的
# 那一行**，用 ^ 指住出错的那个词，再给改法。两件事与「猜不猜得到」无关：
#
#   1. 回显命令行。猜得到时它让人看清错的是哪个词；猜不到时它是唯一的定位信息。
#   2. **绝不打印整篇帮助**。那几十行会在终端里滚过一整屏，把真正有用的两行
#      （错在哪个词、该敲什么）推到看不见的地方 —— 想知道全部命令的人自己会敲
#      `finx -h`。所以这里只留一条指向它的提示。
#
# 颜色与普通消息同一套：出错的那个词、脱字符、Error 行用 error，改法里的正确
# 写法用 ok，指路用的命令名用 cmd。

# 编辑距离，两行滚动数组。输入都是命令名或旗标名，长度不超过二十几个字符。
sub edit_distance {
	my ($a, $b) = @_;
	return length($a) > length($b)
		? edit_distance($b, $a) : _edit_distance_into($a, $b);
}

sub _edit_distance_into {
	my ($a, $b) = @_;
	# $a 是短的那个，只为了少分配一行
	my @prev = (0 .. length $b);
	foreach my $i (1 .. length $a) {
		my @cur = ($i);
		foreach my $j (1 .. length $b) {
			my $cost = substr($a, $i - 1, 1) eq substr($b, $j - 1, 1) ? 0 : 1;
			my $v = $prev[$j] + 1;
			$v = $cur[$j - 1] + 1 if $cur[$j - 1] + 1 < $v;
			$v = $prev[$j - 1] + $cost if $prev[$j - 1] + $cost < $v;
			$cur[$j] = $v;
		}
		@prev = @cur;
	}
	return $prev[length $b];
}

# 从候选里挑一个最像的。只在两种情况下认：前缀关系（instal / install、
# --connect-time / --connect-timeout），或者编辑距离不超过 2（instll / install）。
# 差得远就不猜 —— 猜错比不猜更糟，用户照着改还会再撞一次。
sub nearest_name {
	my ($word, @candidates) = @_;
	return undef if !defined $word || length($word) < 3;

	my ($best, $best_score);
	foreach my $name (@candidates) {
		my $score;
		if (index($name, $word) == 0 || index($word, $name) == 0) {
			$score = 0;
		} elsif (abs(length($name) - length($word)) <= 2) {
			$score = edit_distance($word, $name);
			next if $score > 2;
		} else {
			next;
		}
		if (!defined $best_score
			|| $score < $best_score
			|| ($score == $best_score && length($name) < length($best))) {
			($best, $best_score) = ($name, $score);
		}
	}
	return $best;
}

# 回显命令行 + 脱字符行。
#
#   $indent     行首缩进
#   \@words     要回显的词
#   $bad        出错的下标
#   $span       标红的长度（只标旗标名时用，值部分留着原样）；undef = 整个词
#
# 返回两行（都以换行结尾）。缩进与脱字符都按**未上色**的长度算 —— 逃逸码零宽
# 但计入 length，混进来 ^ 就会错位。
sub _replay_and_caret {
	my ($indent, $words, $bad, $span) = @_;
	my @shown;
	foreach my $i (0 .. $#$words) {
		my $word = $words->[$i];
		if ($i != $bad) {
			push @shown, $word;
			next;
		}
		if (defined $span) {
			my ($name, $rest) = $word =~ /^([^=]*)(=.*)?$/;
			push @shown, paint($name, 'error') . (defined $rest ? $rest : '');
		} else {
			push @shown, paint($word, 'error');
		}
	}

	my $before = $indent . join(' ', @{$words}[0 .. $bad - 1]);
	$before .= ' ' if $bad > 0;
	my $width = defined $span ? $span : length($words->[$bad]);

	return $indent . join(' ', @shown) . "\n"
		. paint((' ' x length($before)) . ('^' x $width), 'error') . "\n";
}

=over 4

=item unknown_command_message

  my $text = unknown_command_message(\@argv, $cmd, $near);

The whole message for a mistyped subcommand. C<\@argv> is what the user actually
typed (without the program name), C<$cmd> is the word taken as the command, and
C<$near> is the guessed correct command (pass undef when there is no guess).

=back

=cut
sub unknown_command_message {
	my ($argv, $cmd, $near) = @_;
	my @words = @{ $argv || [$cmd] };
	$cmd = '' unless defined $cmd;

	# 指住用户当成命令的那个词。找不到（比如 argv 与 $cmd 对不上）就退回到
	# 第一个不以 - 开头的词，至少还能定位。
	my $bad;
	foreach my $i (0 .. $#words) {
		if ($words[$i] eq $cmd) { $bad = $i; last }
	}
	if (!defined $bad) {
		foreach my $i (0 .. $#words) {
			if ($words[$i] !~ /^-/) { $bad = $i; last }
		}
	}

	my $text = paint("Error: Unknown command or argument.", 'error') . "\n\n";
	$text .= _replay_and_caret('   ', \@words, $bad) . "\n" if defined $bad;

	if (defined $near && length $near) {
		my @fixed = @words;
		$fixed[$bad] = $near if defined $bad;
		my $shown = join ' ', map {
			$_ eq $near ? paint($_, 'ok') : $_
		} @fixed;
		$text .= paint("Did you mean:", 'bold') . " $shown\n\n";
		$text .= '   ' . paint($cmd, 'warn') . ' is not a command. '
			. 'The one you want is ' . paint($near, 'ok') . ".\n\n";
	}
	$text .= '   For the full list: ' . paint('finx -h', 'cmd') . "\n";
	return $text;
}

=over 4

=item unknown_option_message

  my $text = unknown_option_message($command, \@argv, $token, $near);

The whole message for a mistyped flag. C<$command> is the current subcommand (the
empty string for global options), C<\@argv> is what the user actually typed
(without the program name), C<$token> is the whole offending piece (such as
C<--connect-time=12s>), and C<$near> is the guessed flag (pass undef when there is
no guess).

Only the flag name is coloured and underlined with C<^>; the value part (C<=12s>)
is left alone, so it is obvious at a glance that the name is wrong and not the
value.

=back

=cut
sub unknown_option_message {
	my ($command, $argv, $token, $near) = @_;
	my @words = @{ $argv || [] };
	my $cmd = defined $command ? $command : '';
	$cmd =~ s/^\s+//;

	my $bad;
	foreach my $i (0 .. $#words) {
		if ($words[$i] eq $token) { $bad = $i; last }
	}
	my ($span) = $token =~ /^([^=]*)/;
	$span = length $token unless defined $span && length $span;

	my $for = length $cmd ? "for `finx $cmd`" : 'for `finx`';
	my $text = paint("Error: illegal option $span $for", 'error')
		. "\n\n";
	$text .= _replay_and_caret('   ', \@words, $bad, length $span)
		. "\n" if defined $bad;

	if (defined $near && length $near) {
		$text .= paint("Next:", 'bold')
			. ' Did you mean ' . paint($near, 'ok') . "?\n\n";
	}
	$text .= paint(length $cmd ? "finx $cmd --help" : 'finx --help', 'cmd')
		. ' lists the flags ' . (length $cmd ? 'this command' : 'finx')
		. " accepts\n";
	return $text;
}

1;
