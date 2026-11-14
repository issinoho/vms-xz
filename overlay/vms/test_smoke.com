$! TEST_SMOKE.COM - smoke test for the built XZ Utils ([.BIN_<arch>])
$!
$! Usage:  @[.VMS]TEST_SMOKE [bin-directory]
$! P1: where XZ.EXE, XZDEC.EXE and LZMAINFO.EXE are (default [.BIN_<arch>];
$!     the install check passes XZ$ROOT:[BIN]).
$!
$! Includes upstream's test files (tests/files, as tests/test_files.sh uses
$! them): every good-* file must test clean and every bad-* file (and
$! unsupported-*.lz) must be an error.  Files are compared byte by byte with
$! VSI Perl, or where there is none (OpenVMS Alpha) with SAME.C.
$!
$ set noon
$ saved_default = f$environment("DEFAULT")
$ proc = f$environment("PROCEDURE")
$ vmsdir = f$parse(proc,,,"DEVICE") + f$parse(proc,,,"DIRECTORY")
$ set default 'vmsdir'
$ set default [-]
$ top = f$environment("DEFAULT")
$ files = top - "]" + ".TESTS.FILES]"
$ arch = f$edit(f$getsyi("ARCH_NAME"), "UPCASE")
$ bin = f$parse("[.BIN_''arch']",,,"DEVICE") + f$parse("[.BIN_''arch']",,,"DIRECTORY")
$ if p1 .nes. "" then bin = p1
$! The library and headers: the tree's install tree, or the kit's (P1 given).
$ inc = f$parse("[.INSTALL_''arch'.INCLUDE]",,,"DEVICE") + f$parse("[.INSTALL_''arch'.INCLUDE]",,,"DIRECTORY")
$ olb = f$parse("[.INSTALL_''arch'.LIB]LIBLZMA.OLB")
$ if p1 .nes. ""
$ then
$   inc = bin - "BIN]" + "INCLUDE]"
$   olb = bin - "BIN]" + "LIB]LIBLZMA.OLB"
$ endif
$ write sys$output "SMOKE: testing ", bin
$ xz = "$" + bin + "XZ.EXE"
$ xzdec = "$" + bin + "XZDEC.EXE"
$ lzmainfo = "$" + bin + "LZMAINFO.EXE"
$ pass = 0
$ fail = 0
$ perl_setup = f$search("SYS$COMMON:[PERL-5_*]PERL_SETUP.COM")
$ if perl_setup .nes. "" then @'perl_setup'
$ if f$search("SMOKE.DIR") .eqs. "" then create/directory [.SMOKE]
$ set default [.SMOKE]
$ set process/parse_style=extended
$! SAME a b [T]: success if the two files hold the same bytes.  With T the files
$! are read as text files (a variable-length record file comes back with its
$! line ends), otherwise as raw bytes.
$ if perl_setup .nes. ""
$ then
$   create same.pl
open my $a, '<:raw', $ARGV[0] or exit 2; open my $b, '<:raw', $ARGV[1] or exit 2;
local $/; my $x = <$a>; my $y = <$b>; exit($x eq $y ? 0 : 1);
$!  PERL_SETUP defines perl as a foreign command symbol; DCL expands only the
$!  first symbol of a command, so put its value, not its name, in SAME.
$   same = perl + " same.pl"
$ else
$   write sys$output "SMOKE: no VSI Perl; comparing files with SAME.C"
$   create same.c
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv)
{
    FILE *a, *b;
    int c, d;
    if (argc < 3) exit(44);
    a = fopen(argv[1], argc > 3 ? "r" : "rb");
    b = fopen(argv[2], argc > 3 ? "r" : "rb");
    if (a == NULL || b == NULL) exit(44);
    do {
        c = getc(a);
        d = getc(b);
        if (c != d) exit(44);
    } while (c != EOF);
    return 0;
}
$   cc/nolist/float=ieee_float/object=same.obj same.c
$   link/nomap/executable=same.exe same.obj
$   same = "$" + f$environment("DEFAULT") + "SAME.EXE"
$ endif
$!
$! 1. version
$ define/user sys$output out.txt
$ xz --version
$ search/nooutput out.txt "xz (XZ Utils) 5"
$ sev = $severity
$ name = "version"
$ gosub check_success
$!
$! 2. a text file (variable-length records) round trip: its lines survive
$ create text.txt
The quick brown fox jumps over the lazy dog.
OpenVMS, IA64, x86-64 and Alpha.
$ copy/nolog text.txt orig.txt
$ xz "-k" text.txt
$ sev = $severity
$ if sev .eq. 1 .and. f$search("text.txt.xz") .eqs. "" then sev = 2
$ if sev .eq. 1
$ then
$   xz "-t" text.txt.xz
$   sev = $severity
$ endif
$ if sev .eq. 1
$ then
$   delete/nolog text.txt;*
$   xz "-d" text.txt.xz
$   sev = $severity
$   if sev .eq. 1
$   then
$     same text.txt orig.txt t
$     if $status .ne. 1 then sev = 2
$   endif
$ endif
$ name = "text file round trip (-k, -t, -d)"
$ gosub check_success
$!
$! 3. a binary file (the xz image itself, fixed-length records) round trip at
$!    the default level 6 (-9 needs about 674 MiB, more than a default
$!    PGFLQUOTA allows)
$ copy/nolog 'bin'XZ.EXE bin.dat
$ copy/nolog bin.dat binorig.dat
$ xz bin.dat
$ sev = $severity
$ if sev .eq. 1
$ then
$   xz "-d" bin.dat.xz
$   sev = $severity
$   if sev .eq. 1
$   then
$     same bin.dat binorig.dat
$     if $status .ne. 1 then sev = 2
$   endif
$ endif
$ name = "binary file round trip (-d)"
$ gosub check_success
$!
$! 4. xz -l lists a file
$ xz "-k" "-f" text.txt
$ define/user sys$output out.txt
$ xz "-l" text.txt.xz
$ search/nooutput out.txt "Ratio"
$ sev = $severity
$ name = "xz -l lists a file"
$ gosub check_success
$!
$! 5. xzdec decompresses to standard output
$ define/user sys$output dec.txt
$ xzdec text.txt.xz
$ sev = $severity
$ if sev .eq. 1
$ then
$   search/nooutput/exact dec.txt "OpenVMS, IA64, x86-64 and Alpha."
$   sev = $severity
$ endif
$ name = "xzdec decompresses to standard output"
$ gosub check_success
$!
$! 6. lzmainfo reads a .lzma file
$ xz "--format=lzma" "-k" text.txt
$ define/user sys$output out.txt
$ lzmainfo text.txt.lzma
$ search/nooutput out.txt "Uncompressed size"
$ sev = $severity
$ name = "lzmainfo reads a .lzma file"
$ gosub check_success
$!
$! 7. upstream's good-* files all test clean
$ bad = 0
$ count = 0
$good_loop:
$ f = f$search("''files'good-*.*", 1)
$ if f .eqs. "" then goto good_done
$ count = count + 1
$ define/user sys$error nla0:
$ xz "-t" 'f'
$ if $severity .ne. 1
$ then
$   bad = bad + 1
$   write sys$output "   failed: ", f$parse(f,,,"NAME") + f$parse(f,,,"TYPE")
$ endif
$ goto good_loop
$good_done:
$ sev = 1
$ if bad .gt. 0 .or. count .eq. 0 then sev = 2
$ name = "upstream's ''count' good-* files test clean"
$ gosub check_success
$!
$! 8. upstream's bad-* files (and unsupported-*.lz) are all errors
$ bad = 0
$ count = 0
$bad_loop:
$ f = f$search("''files'bad-*.*", 2)
$ if f .eqs. "" then goto bad_more
$ gosub bad_one
$ goto bad_loop
$bad_more:
$ f = f$search("''files'unsupported-*.lz", 3)
$ if f .eqs. "" then goto bad_done
$ gosub bad_one
$ goto bad_more
$bad_done:
$ sev = 1
$ if bad .gt. 0 .or. count .eq. 0 then sev = 2
$ name = "upstream's ''count' bad-* files give errors"
$ gosub check_success
$!
$! 9. a program compiled with the default /NAMES links with LIBLZMA.OLB
$!    (lzma.h declares the API /NAMES=(AS_IS,SHORTENED), patch 0004)
$ create ver.c
#include <stdio.h>
#include <lzma.h>
int main (void)
{
  lzma_stream strm = LZMA_STREAM_INIT;
  if (lzma_easy_encoder (&strm, 6, LZMA_CHECK_CRC64) != LZMA_OK)
    return 1;
  lzma_end (&strm);
  printf ("liblzma %s\n", lzma_version_string ());
  return 0;
}
$ cc/nolist/include_directory='inc' ver.c
$ link/nomap ver, 'olb'/library
$ define/user sys$output out.txt
$ run ver
$ search/nooutput out.txt "liblzma 5"
$ sev = $severity
$ name = "a program compiled /NAMES=UPPERCASE links with LIBLZMA.OLB"
$ gosub check_success
$!
$! 10. a missing file is an error
$ define/user sys$error nla0:
$ xz "-d" nonexistent.xz
$ sev = $severity
$ name = "a missing file gives an error status"
$ gosub check_failure
$!
$ write sys$output "SMOKE: ''pass' passed, ''fail' failed"
$ delete/nolog *.*;*
$ set default [-]
$ set file/protection=o:rwed SMOKE.DIR
$ delete/nolog SMOKE.DIR;
$ set default 'saved_default'
$ if fail .eq. 0 then exit 1
$ exit 44
$!
$bad_one:
$ count = count + 1
$ define/user sys$error nla0:
$ xz "-t" 'f'
$ s = $severity
$ if s .ne. 2 .and. s .ne. 4
$ then
$   bad = bad + 1
$   write sys$output "   accepted: ", f$parse(f,,,"NAME") + f$parse(f,,,"TYPE"), " (severity ", s, ")"
$ endif
$ return
$!
$check_success:
$ if sev .eq. 1
$ then
$   pass = pass + 1
$   write sys$output "PASS: ", name
$ else
$   fail = fail + 1
$   write sys$output "FAIL: ", name, " (severity ", sev, ")"
$   if f$search("out.txt") .nes. ""
$   then
$     write sys$output "   output was:"
$     type out.txt;0
$   endif
$ endif
$ return
$!
$check_failure:
$ if sev .eq. 2 .or. sev .eq. 4
$ then
$   pass = pass + 1
$   write sys$output "PASS: ", name
$ else
$   fail = fail + 1
$   write sys$output "FAIL: ", name, " (severity ", sev, ", expected an error)"
$ endif
$ return
