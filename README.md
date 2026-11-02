## 🧩 Finx

A package manager for macOS that builds from source, built on the `dpkg` / `apt` stack.

**English** · [简体中文](./README.zh-Hans.md)

> **Under development.** Interfaces and behaviour may change without notice.

## 🧩 Official Website

[finx.sh](https://finx.sh)

## 🧩 About Finx

**Finx** is the continuation of **Fink**, the long-standing macOS package manager that maintains its own directory hierarchy with the help of `dpkg`. It downloads original source releases, patches them when necessary, configures them for Darwin, then compiles and installs them. Package descriptions — what to build, which patches to apply, what the result depends on — are maintained separately from the code and updated on their own schedule.

The `x` stands for **extension**. Dependency solving and side-effect control in `dpkg` / `apt` are still ahead of what most modern package managers offer, so Finx keeps that kernel rather than replacing it. What gets extended is everything around it: the install prefix, the documentation, and the parts that made Fink hard to maintain.

## 🧩 Why Finx

1. **Real dependency solving.** `Depends`, `Conflicts`, `Provides`, virtual packages and `shlibs` symbol dependencies are computed by the package manager, not by an "install this before that" convention.
2. **Controlled side effects.** `conffiles` keep configuration you edited across upgrades, and the four maintainer scripts — `preinst`, `postinst`, `prerm`, `postrm` — define exactly what happens at each step.
3. **Resolved before landing.** A consistency pass works out which packages must be temporarily removed to satisfy an install, instead of discovering the conflict halfway through.
4. **One canonical prefix.** Everything lives under `/opt/finx`. The old split between `/sw` and `/opt/sw`, decided by macOS version, is gone.
5. **Source and binary distribution.** Download a prebuilt `.deb` when one exists, compile when it does not; both take the same install path.
6. **Perl and Shell only.** No compiled dependencies, so reading the code does not require a working toolchain first.
7. **Real locking.** The `dpkg` database lock is taken before `exec`, so the child process inherits it and concurrent operations cannot trample each other.
8. **Package operations run as root, like MacPorts.** `finx` invokes `sudo` itself; the prefix stays owned by root, and one system-wide binary distribution serves everyone.

## 🧩 Supported macOS Versions

The current distribution tree is `10.9-libcxx`, covering **macOS 10.9 and later** on both Intel and Apple silicon.

## 🧩 Latest Version

`0.45.99.git` — development tree, not a release.

## 🧩 Install Finx

Finx starts from the host C compiler: it compiles a `dpkg` into a scratch tree first, uses that `dpkg` to install the base packages into `/opt/finx`, then removes the scaffolding.

**Requirements:** macOS 10.9+, the Xcode Command Line Tools, and `/usr/bin/perl` (shipped with macOS).

```bash
xcode-select --install
sudo xcodebuild -license
```

Then, from a checkout:

```bash
cd finx
./bootstrap
```

`./bootstrap` is interactive: it asks how to gain root, where to install, and a few configuration questions. To skip the prefix question, pass it as the first argument:

```bash
./bootstrap /opt/finx
```

The binary distribution only works when Finx is installed at `/opt/finx`, because `.deb` payloads record that path at build time.

After it finishes:

```bash
. /opt/finx/bin/init.sh
```

To make that permanent, let the bundled helper edit it (it asks first):

```bash
/opt/finx/bin/pathsetup.sh
```

## 🧩 Using Finx

```bash
finx install wget       # install a package
finx list               # list available packages
finx describe wget      # show the package description
finx remove wget        # remove it, keeping configuration files
finx purge wget         # remove it, configuration files included
finx selfupdate         # update the package manager itself
finx update-all         # update every installed package
```

Package operations need root; `finx` runs `sudo` itself, so you do not add it by hand.

`USAGE` documents the full command set. Build artefacts are not cleaned up automatically — use `finx cleanup` to drop source tarballs, `.deb` files and stale build locks.

## 🧩 Relationship to Fink

| | Fink | Finx |
| --- | --- | --- |
| Install prefix | `/sw`, later `/opt/sw` | `/opt/finx` |
| Package kernel | `dpkg` / `apt` | `dpkg` / `apt` (unchanged) |
| Language | Perl and Shell | Perl and Shell (unchanged) |
| Distribution trees | one per macOS release | unchanged, `10.9-libcxx` current |
| Documentation | scattered, lagging behind releases | consolidated under `docs/` |
| Installer | source bootstrap only | seed-based installer (in progress) |

The command is still named `finx` and package names are unchanged. Renaming them would invalidate every package description in existence for no functional gain.

## 🧩 For Developers

```bash
make test               # integrity check plus the full test suite
make format             # indentation check (Perl uses tabs, shell uses 4 spaces)
./inject.pl /opt/finx   # install the working copy into an existing installation
```

- [`docs/TECHNICAL-GUIDE.md`](./docs/TECHNICAL-GUIDE.md) — the bootstrap chain, the packaging pipeline and the `dpkg` patches.
- [`AGENTS.md`](./AGENTS.md) — conventions for anyone, human or agent, changing this tree.
- [`STYLE`](./STYLE) — the original style guide.
- [`INSTALL`](./INSTALL) — the long-form installation procedure.

## 🧩 License

Finx keeps Fink's license and is released under the **GNU General Public License, version 2, or (at your option) any later version** — SPDX `GPL-2.0-or-later`. That is the wording every source file inherited from Fink carries; see [`LICENSE`](./LICENSE) for the full text.
