# CLAUDE.md

Guidance for working in this repository: a port of XZ Utils to OpenVMS (IA64 and x86-64)
that stores only our deltas over the upstream release tarball. It is built with exactly the
methods of its sibling `~/projects/vms-grep` (github.com/issinoho/vms-grep), and the tools
are copies of vms-m4's (vms-wget's, grep's, extended). Read README.md first; it describes the workflow and design. This
file covers the rules and the pitfalls.

## Ground rules

- **Never edit `staging/`, `cache/` or `out/`.** They are regenerated. Every VMS change is
  either a patch (`patches/NNNN-*.patch`, listed in `patches/series`) or a new file in
  `overlay/`. `tools/prepare.sh` refuses overlay files that would replace upstream files.
- **Change an upstream file with a patch.** Make a pristine copy under `a/` and an edited
  copy under `b/`, run `diff -u a/<path> b/<path>`, and put a `Subject:` line and a short
  explanation above the diff. Guard VMS-only code with `#ifdef __VMS` so the patch could go
  upstream. Patches to the same file stack, so diff against the tree as it stands after the
  earlier patches.
- **Configuration answers** go in `overlay/vms/config/vms-manual.site`, each with a comment
  explaining why. Plain `var=value` lines there override the generated
  `configure-<node>.cache`. Overriding a gnulib result often needs its `gl_cv_*` variable
  too, not just `ac_cv_*` (`mempcpy` needed `gl_cv_onwards_func_mempcpy`).
- **Test exceptions** go in `overlay/vms/tests.skip` (not run) or `overlay/vms/tests.xfail`
  (expected to fail), always with a reason. Before calling a failure "environmental",
  verify xz's behaviour natively; `docs/TESTING.md` records how. Upstream's own
  `XFAIL_TESTS` are picked up automatically.
- **Committed files must not contain real node details.** Use `<ia64-host>`, `<x86-host>`
  and `DISK$USER:[USERNAME.VMS_GREP]`. The real values live only in the git-ignored
  `tools/nodes.conf`.
- Keep `docs/TESTING.md` and the README status table in step with test results.

## xz specifics

- **Host configure** as in vms-xz (`tools/vms_configure.sh`, memo cache).  Tests
  without a cache variable get gcc's answer in the host run: `config-h-undef.txt` turns
  those off and `prepare.sh` compares `config.h` with the VSI C run's (fails if they differ).
- **liblzma** is the library group with its own `LIB_CFLAGS` (gen_mms.py
  `GEN_MMS_LIB_CFLAGS`, `GEN_MMS_LIB_BASE=src/liblzma`).
- **Subheaders:** VSI C does not resolve `"lzma/version.h"` against a VMS include
  directory; on VMS lzma.h includes `lzma_*.h`, which prepare.sh copies flat (patch 0004).
- **Upstream VMS code** exists (file_io.c, suffix.c, tuklib_physmem.c) but predates
  `_USE_STD_STAT` and xz 5.8's directory fsync (patches 0001, 0003).
- Upstream's `tests/files` (good/bad/unsupported) are part of the smoke test.
- **Text files:** a VMS text file (variable-length/VFC records) read in binary mode loses
  its line breaks; the program opens such files in text mode (`st_fab_rfm`), so the
  compressed data has LF lines.  Binary data (stream, fixed records) stays binary.
- **Library names:** compiled `/NAMES=(AS_IS,SHORTENED)`; the public headers declare the
  API under `#pragma names as_is, shortened`, so `/NAMES=UPPERCASE` programs link (the smoke
  test checks).
- **Exit status:** `exit()` goes through `vms_exit()` (`vms/vms_exit.c`); a `return` from
  `main` bypasses it, so `main` ends with `exit()` on VMS.
- **Smoke tests** compare files byte for byte with VSI Perl
  (`SYS$COMMON:[PERL-5_*]PERL_SETUP.COM`); DIFFERENCES compares records.

## Commands

```sh
tools/prepare.sh                        # always first after changing patches/overlay
tools/build.sh <ia64|x86> [ALL|CLEAN] [KEEP_GOING]
tools/test.sh <node>                    # smoke test
tools/gnvtest.sh x86 [tests...]         # upstream suite (x86 only; ~90 min for all)
tools/vms.sh <node> dcl '<cmd>' ...     # run DCL; also run/batch/put/get
tools/kit.sh <node>                     # PCSI kit -> out/kits/ (producer ISSINOHO)
tools/installcheck.sh <node>            # install kit, verify, smoke-test, remove (changes system; ask first)
tools/vms_configure.sh <node>           # once per upstream release, 45-65 min
```

Run long operations (full builds take ~30 min on IA64 and longer on the x86 VM; the test
suite ~90 min; configure up to 70 min) with `run_in_background` and poll for completion.
MMS does not track compiler flags: after changing `ccflags.txt` or `CFLAGS` in
`descrip.mms`, run `tools/build.sh <node> CLEAN` first.

## VMS and tooling pitfalls (learned the hard way)

- **Use `tools/vms.sh`, never raw `ssh host cmd`.** Raw ssh output is often lost, and
  sessions sometimes never close. vms.sh logs to a file and waits for a completion marker.
- **Never use `WAIT` in DCL run over ssh**; it hangs (batch jobs are fine).
- **Never edit a bash script that is running.** bash reads scripts incrementally. Replace
  long-running tools atomically (write a copy, then `mv`).
- **Don't use `pkill -f` / `pgrep -f`** with a pattern that also matches your own shell's
  command line. Kill by explicit PID. On VMS, stop only processes this session started
  (they are network/batch processes of the work account); leave interactive sessions alone.
- **DCL details:**
  - `F$SEARCH` with a wildcard needs a stream id when other `F$SEARCH` calls happen in the
    same loop.
  - Batch jobs default to `/LIST` and `/MAP`.
  - DCL command lines are limited to about 4096 bytes (hence the wildcard librarian step).
  - `CALL` arguments are upper-cased unless quoted.
  - `SYS$LOGIN:[.X]` is not valid on these nodes.
- **`sftp put -r` into an existing directory nests a copy**; push.sh uploads file by file.
- **Run `tools/prepare.sh` after every change to `patches/` or `overlay/`.** build.sh and
  kit.sh push whatever is in `staging/`; forgetting this once shipped a stale kit.
- **stdout on VMS is often record-oriented** (terminal, `/OUTPUT` log, mailbox). The CRTL
  turns each `fwrite` item into a record (the sed and grep ports write with `putc`), and a host-side
  `grep` treats output containing a NUL as binary (use `grep -a`).
- **GNV quirks:**
  - Shell functions inside pipelines get the wrong arguments.
  - Empty arguments are dropped when bash runs a VMS image.
  - VMS pipes have no SIGPIPE.
  - A `timeout` that fires in a batch job kills the whole process tree.
  - IA64's GNV is bash 1.14 and cannot run the upstream suite; use the regex tables there.
  - `printf` to a VMS file ends every write with a newline (each write is a record), so
    tests that build exact bytes with printf fail; verify them natively with VSI Perl.
  - An assignment prefix on a function call (`LC_ALL=x func`) stays set afterwards.
- **CRTL quirks** that matter (shared with grep and sed) are documented in
  vms-grep's `docs/vms-environment.md`:
  - no `#include_next`; text-library includes instead;
  - `open()` of a directory fails;
  - `setlocale("")` ignores environment variables;
  - UTF-8 decoding bugs;
  - `mempcpy` is a macro;
  - argument case under traditional parse style.

## Commits

Commit in logical steps with messages that explain the VMS reason for each change. Don't
push without the user asking. The GitHub remote is `origin`
(github.com/issinoho/vms-xz), branch `main`.
