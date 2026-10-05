$! XZ$SETUP.COM - define the XZ Utils commands for a user
$!
$! Add to LOGIN.COM (or SYS$MANAGER:SYLOGIN.COM for everyone):
$!     $ @XZ$ROOT:[000000]XZ$SETUP.COM
$!
$! Quote upper-case options, or SET PROCESS/PARSE_STYLE=EXTENDED: traditional DCL
$! parsing changes the case of unquoted arguments; batch jobs use the traditional style.
$!
$ if f$trnlnm("XZ$ROOT") .eqs. ""
$ then
$   write sys$error "XZ$SETUP: XZ$ROOT is not defined; run XZ$STARTUP.COM first"
$   exit 44
$ endif
$ xz       :== $XZ$ROOT:[BIN]XZ.EXE
$ unxz     :== "$XZ$ROOT:[BIN]XZ.EXE -d"
$ xzcat    :== "$XZ$ROOT:[BIN]XZ.EXE -dc"
$ xzdec    :== $XZ$ROOT:[BIN]XZDEC.EXE
$ lzmainfo :== $XZ$ROOT:[BIN]LZMAINFO.EXE
$ exit 1
