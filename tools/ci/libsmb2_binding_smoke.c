#include "shim.h"

#define REQUIRE_SYMBOL(name) \
  static __typeof__(&name) require_##name __attribute__((used)) = &name

REQUIRE_SYMBOL(smb2_init_context);
REQUIRE_SYMBOL(smb2_close_context);
REQUIRE_SYMBOL(smb2_destroy_context);
REQUIRE_SYMBOL(smb2_set_timeout);
REQUIRE_SYMBOL(smb2_set_version);
REQUIRE_SYMBOL(smb2_set_security_mode);
REQUIRE_SYMBOL(smb2_set_sign);
REQUIRE_SYMBOL(smb2_set_seal);
REQUIRE_SYMBOL(smb2_set_authentication);
REQUIRE_SYMBOL(smb2_set_domain);
REQUIRE_SYMBOL(smb2_set_user);
REQUIRE_SYMBOL(smb2_set_password);
REQUIRE_SYMBOL(smb2_connect_share);
REQUIRE_SYMBOL(smb2_disconnect_share);
REQUIRE_SYMBOL(smb2_get_dialect);
REQUIRE_SYMBOL(smb2_get_error);
REQUIRE_SYMBOL(smb2_opendir);
REQUIRE_SYMBOL(smb2_readdir);
REQUIRE_SYMBOL(smb2_closedir);
REQUIRE_SYMBOL(smb2_stat);
REQUIRE_SYMBOL(smb2_open);
REQUIRE_SYMBOL(smb2_pread);
REQUIRE_SYMBOL(smb2_close);

int main(void) {
  struct smb2_context *context = require_smb2_init_context();
  if (context == NULL) {
    return 1;
  }
  require_smb2_destroy_context(context);
  return 0;
}
