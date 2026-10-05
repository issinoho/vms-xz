$! XZ$STARTUP.COM - system startup for XZ Utils on OpenVMS
$!
$! Installed by PCSI into SYS$STARTUP.  Defines the system logical name
$! XZ$ROOT, pointing at the installed [XZ] directory.  To run it at every
$! boot, add this line to SYS$MANAGER:SYSTARTUP_VMS.COM:
$!
$!     $ @SYS$STARTUP:XZ$STARTUP.COM
$!
$! P1 = "INSTALL": also print the post-installation tasks (PCSI runs it so).
$! P1 = "REMOVE":  deassign XZ$ROOT instead (PCSI runs it so at removal).
$!
$! Users then define the commands with
$!     $ @XZ$ROOT:[000000]XZ$SETUP.COM
$!
$ set noon
$ mode = f$edit(p1, "UPCASE")
$ if mode .eqs. "REMOVE"
$ then
$   if f$trnlnm("XZ$ROOT", "LNM$SYSTEM_TABLE") .nes. "" then -
        deassign/system/executive_mode XZ$ROOT
$   exit 1
$ endif
$!
$! This procedure sits in <destination>[SYS$STARTUP]; the product is in
$! <destination>[XZ].  Rooted logicals need the physical form:
$! DKA0:[SYS0.SYSCOMMON.SYS$STARTUP] -> DKA0:[SYS0.SYSCOMMON.XZ.]
$ proc = f$environment("PROCEDURE")
$ dev = f$parse(proc,,,"DEVICE","NO_CONCEAL")
$ dir = f$edit(f$parse(proc,,,"DIRECTORY","NO_CONCEAL"), "UPCASE") - "]["
$ root = dir - "SYS$STARTUP]" + "XZ.]"
$ if root .eqs. dir + "XZ.]"
$ then
$   write sys$error "XZ$STARTUP: expected to be in a [SYS$STARTUP] directory, not ''dir'"
$   exit 44
$ endif
$ root = root - ".000000"
$ define/system/executive_mode/translation_attributes=concealed XZ$ROOT 'dev''root'
$ if f$search("XZ$ROOT:[BIN]XZ.EXE") .eqs. ""
$ then
$   write sys$error "XZ$STARTUP: XZ.EXE not found under ''dev'''root'"
$   exit 44
$ endif
$ if mode .nes. "INSTALL" then exit 1
$ say = "write sys$output"
$ say ""
$ say "    Post-installation tasks for XZ Utils"
$ say ""
$ say "    At system startup: to define XZ$ROOT at every boot, add this line to"
$ say "    SYS$MANAGER:SYSTARTUP_VMS.COM:"
$ say "    $ @SYS$STARTUP:XZ$STARTUP.COM"
$ say "    For each user: to define the commands, add this line to LOGIN.COM:"
$ say "    $ @XZ$ROOT:[000000]XZ$SETUP.COM"
$ say ""
$ say "    PRODUCT REMOVE XZ removes the product and deassigns XZ$ROOT."
$ say ""
$ exit 1
