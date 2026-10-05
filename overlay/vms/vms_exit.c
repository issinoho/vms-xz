/* vms_exit.c - exit() for XZ Utils on OpenVMS.

   With _POSIX_EXIT the VSI C RTL encodes exit(n) as %X35A000 + n*8 + 1,
   which has success severity, so to DCL a failed run looks successful.
   src/common/sysdefs.h (patch 0002) routes exit() here.  Under a Unix shell (GNV bash:
   SHELL is set and is not "DCL") keep the POSIX exit, which the shell
   decodes as $?.  Under DCL, exit code 0 is success, 2 (xz: something
   worth a warning happened) a warning, %X1035A010, and any other code N
   (1: an error) an error-severity status with the message suppressed
   (%X1035A002 + N*8), so $SEVERITY is 2 and ON ERROR fires.  N is always
   (status & %X7F8) / 8.

   Part of the OpenVMS port of XZ Utils (github.com/issinoho/vms-xz), as in
   vms-wget; distributed under the same terms as XZ Utils (0BSD, see COPYING.0BSD).  */

#define VMS_EXIT_IMPLEMENTATION 1
#include <config.h>

#include <stdlib.h>
#include <string.h>

void decc$exit (int status);
void decc$__posix_exit (int status);

void
vms_exit (int status)
{
  const char *shell = getenv ("SHELL");
  if (shell != NULL && strcmp (shell, "DCL") != 0)
    decc$__posix_exit (status);
  if (status == 0)
    decc$exit (1);
  if (status == 2)
    decc$exit (0x10000000 | 0x35A000 | (2 << 3) | 0);
  decc$exit (0x10000000 | 0x35A000 | ((status & 0xFF) << 3) | 2);
}
