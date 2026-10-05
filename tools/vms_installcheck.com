$! VMS_INSTALLCHECK.COM <tree-dir-name> - install the XZ kit, verify, smoke-test
$! the installed image, then remove it.  Changes the system while it runs (PCSI
$! database, SYS$COMMON:[XZ], system logical XZ$ROOT); leaves it as it was.
$ set noon
$ arch = f$edit(f$getsyi("ARCH_NAME"), "UPCASE")
$ base = "I64VMS"
$ if arch .eqs. "X86_64" then base = "X86VMS"
$ tree = f$environment("DEFAULT") - "]" + "." + p1 + "]"
$ kitdir = tree - "]" + ".KIT_''arch']"
$ write sys$output "=== INSTALL from ", kitdir
$ product install XZ /producer=ISSINOHO /base_system='base' /source='kitdir' /options=noconfirm /log
$ write sys$output "=== install status ", $status
$ product show product XZ /producer=ISSINOHO
$ write sys$output "=== VERIFY"
$ write sys$output "startup procedure: [", f$search("SYS$STARTUP:XZ$STARTUP.COM"), "]"
$ show logical XZ$ROOT
$ directory/nohead/notrail XZ$ROOT:[000000...]*.*
$ @XZ$ROOT:[000000]XZ$SETUP.COM
$ show symbol xz
$ xz --version
$ write sys$output "=== SMOKE TEST on installed image"
$ smoke = tree - "]" + ".VMS]TEST_SMOKE.COM"
$ @'smoke' XZ$ROOT:[BIN]
$ write sys$output "=== REMOVE"
$ product remove XZ /producer=ISSINOHO /options=noconfirm /log
$ write sys$output "=== remove status ", $status
$ write sys$output "XZ$ROOT after removal: [", f$trnlnm("XZ$ROOT"), "]"
$ write sys$output "files after removal: [", f$search("SYS$COMMON:[XZ...]*.*"), "]"
$ write sys$output "startup after removal: [", f$search("SYS$STARTUP:XZ$STARTUP.COM"), "]"
$ product show product XZ /producer=ISSINOHO
$ delete/symbol/global xz
$ delete/symbol/global unxz
$ delete/symbol/global xzcat
$ delete/symbol/global xzdec
$ delete/symbol/global lzmainfo
