/* Native Steam's official bootstrap is Intel-only. It must be able to load
 * DYLD_INSERT_LIBRARIES before handing off to the ARM64 client. This slice
 * deliberately installs no hooks; the ARM64 slice contains the real extension.
 */
__attribute__((visibility("default")))
const char *FluentBootstrapOnly(void) { return "x86_64-bootstrap-no-hooks"; }
