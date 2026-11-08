# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private reporting: [Security → Advisories → Report a vulnerability](https://github.com/Fincote/Finx/security/advisories/new).
That channel is visible only to the maintainers.

If you cannot use it, email **zsh@finx.sh** with `SECURITY` in the subject.

What helps most:

- the output of `finx --version` and the macOS version
- the command you ran, **with credentials removed** — replace
  `https://user:pass@mirror/...` with `https://***:***@mirror/...`
- what you expected versus what happened

We aim to acknowledge within three working days, tell you whether we agree it is a
security issue, and keep you informed until it is fixed. Please give us a
reasonable window before publishing.

## What counts as a security issue here

Finx downloads executable software and installs it as root. Its security model
rests on a small number of guarantees; a break in any of them is a vulnerability.

| Guarantee | Where it lives |
| --- | --- |
| **A seed matches the manifest before anything is unpacked.** The `sha256` and byte size in the manifest are both checked; a mismatch aborts. There is no "warn and continue". | `finx-install/install.sh` (`verify_file`) |
| **A payload's links cannot leave the install root.** Every symbolic link is resolved and rejected unless it lands inside the prefix or in one of the exempt system locations. A refusal empties the prefix. | `finx-install/install.sh`, `perlmod/Fink/Links.pm` |
| **The install prefix is `/opt/finx`.** Anything else is refused before the disk is touched. | `finx-install/install.sh` (`enforce_prefix_policy`) |
| **The prefix belongs to root, never to the caller.** | `finx-install/install.sh` (`fix_permissions`) |
| **Builds do not run as root.** Package builds run as `fink-bld` unless a package explicitly opts out. | `perlmod/Fink/Engine.pm`, `BuildAsNobody` |
| **Credentials do not appear in output.** A mirror URL may carry a user and password; everything printed passes through `redact_url` first. | `finx-install/install.sh` (`redact_url`) |
| **Downloads come from the configured domain.** `FINX_INDEX_DOMAIN` / `FINX_SEED_DOMAIN` / `FINX_SOURCE_DOMAIN` / `FINX_DEB_DOMAIN` may be pointed elsewhere, but doing so never skips verification — the seed is still checked against the manifest. | `finx-install/install.sh`, `docs/MIRRORS.md` |
| **The prefix is not the user's to write.** A user-writable prefix would make `bin/dpkg` and `var/lib/dpkg/status` user-controlled root input, because dpkg runs `postinst` as real root. | `finx-install/install.sh` |

Each of these has a test that fails when the guarantee is removed. They are
listed here so a report can point at one of them directly.

### The install prefix is not configurable

**`--prefix` must be `/opt/finx`. This is not a limitation to be worked around;
it is the reason the rest of the model holds.**

Binary packages are not relocatable. A dylib's `install_name` is an absolute
path written at link time, and dpkg's `var/lib/dpkg/info/*.list` records absolute
paths too. A tree installed elsewhere does not run — and worse, the installer
does three things to whatever prefix it is given:

| Step | On `/usr/local` |
| --- | --- |
| `tar -xzf seed.tar.gz -C <prefix>` | overwrites every colliding path |
| the symlink fence, on a bad payload | empties the target's top level |
| `fix_permissions` | `chown -R root:wheel <prefix>` |

The check canonicalises before deciding, so `/opt/../usr/local` and a symlink to
`/usr/local` are judged by where they land, not how they read. Inside
`FINX_TEST` the sandbox root is the boundary instead, and the prefix must stay
under it.

See [`docs/PREFIX.md`](./docs/PREFIX.md) for the full argument.

### Symbolic links: the rule and its exemptions

**If a payload contains a symbolic link, that link must be resolved and checked.
One that lands outside the install root is a defect and must be refused.**

The threat has two halves, and both matter:

| What a malicious payload could do with an escaping link | Why it is a vulnerability |
| --- | --- |
| Point a link at a private file (`~/.ssh/id_rsa`, `~/Library/Messages/…`) and ship a binary that reads through it | Exfiltrates data the user never granted access to |
| Point a link at a path Finx later **writes** through — `resign_macho` walking the tree, `rm -rf` on uninstall | Writes or deletes files outside the install tree |

Archive tooling does not provide this. It filters `../` out of member **names**
and says nothing about link **targets**:

```
lib/innocent.dylib -> /Users/someone/.ssh/id_rsa
```

**Status: enforced since `0.1.0-alpha-0058d3d0`.** Three exits, two
implementations, one exemption table:

| Exit | Implementation | When |
| --- | --- | --- |
| Seed installer (`curl \| bash`) | `finx-install/install.sh` | after extraction, before `resign_macho` |
| `finx install` of a `.deb` | `Fink::Links::offending_in_deb` | before `dpkg -i`, parsing `dpkg-deb -c` |
| A built prefix | `Fink::Links::offending_in_tree` | `make structure` |

Comparison is per path segment, not a string prefix: `/opt/finx2` is not a child
of `/opt/finx`, and `/usrlocal` is not `/usr`. Normalisation is lexical and does
not touch the filesystem, so a dangling link pointing at `/opt/nothing-here` is
judged the same way — it becomes a real escape the moment that path appears.

**Exactly eight exemptions:**

```
/bin   /sbin   /usr/bin   /usr/sbin   /usr/lib   /usr/libexec
/System   /Library/Apple
```

Both reasons must hold at once:

1. **SIP protects them.** Even root cannot write there, so the write half does not
   apply; and upstream artefacts legitimately reference `/usr/bin`.
2. **They hold no private files.** Only system binaries and libraries, so the read
   half does not apply either.

Everything else stays inside the rule: `/Users`, `/Library` outside `Apple/`,
`/private`, `/opt`, `/etc`, `/var`.

Also in scope:

- a crafted index or manifest record that makes the installer delete or write
  outside its own prefix
- a seed that installs files whose paths escape the prefix
- making `finx selfupdate` fetch code from somewhere other than the configured
  domain
- leaking a mirror password through output, a log, or a CI transcript
- a package description whose `%p` expansion writes outside the prefix

## Not security issues

- **A package is malicious or buggy.** Finx verifies that a payload matches the
  manifest, not that the software is benign. Report that upstream.
- **`--from-source` fetches from upstream.** That is what the flag is for.
- **A tree you added yourself is trusted.** Package descriptions under
  `%p/finx/*/finkinfo` are code that runs at build time; whoever can write there
  can already run commands as the builder.
- **An already-installed tree contains a link that escapes.** The fence checks
  payloads at install time. Pre-existing links in a tree installed before
  `0.1.0-alpha-0058d3d0` are not cleaned up. Reinstall to get them checked.
- **`apt` speaks plain HTTP.** `apt 0.5.4` has no https method, so a mirror
  served over HTTP is unauthenticated in transit. This is documented in
  [`docs/MIRRORS.md`](./docs/MIRRORS.md) and is a known limitation, not a
  vulnerability report. Checksum verification of the seed does not extend to
  packages fetched by `apt` itself.

## Supported versions

Fixes land on the current alpha line and reach users through the installer
(`sh.finx.sh`) and through seeds. There is no backport policy yet: the project is
pre-1.0 and there is one line.

| Version | Supported |
| --- | --- |
| `1.0.0-beta4` (current) | ✅ |
| anything older | ❌ |

## For maintainers

If a mirror password is exposed — in an issue, a log, a screenshot, a CI
transcript, a release asset — **rotate it first and investigate second.** Assume
it is already harvested. Rotating the credential does more than deleting the
message, because the message has already been copied.

Two habits that keep this cheap:

- Never paste raw installer output into an issue. `redact_url` covers what the
  installer prints, but `curl -v` output does not go through it.
- When a fix is a guard, add the test that fails without it, and say in the
  release notes which test it is. A guard nobody tests is a comment.
