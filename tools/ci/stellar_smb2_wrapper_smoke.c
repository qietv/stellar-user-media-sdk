#include "stellar_smb2_wrapper.h"

int main(void) {
  stellar_smb2_entry_list list = {0};
  stellar_smb2_client *client = 0;
  stellar_smb2_connection_config config = {
      .server = "127.0.0.1:1",
      .share = "unavailable",
      .username = "guest",
      .password = "",
      .version = STELLAR_SMB2_VERSION_ANY,
      .security_mode = 1,
      .timeout_seconds = 1,
  };

  stellar_smb2_entry_list_destroy(&list);
  if (stellar_smb2_client_connect(&config, &client) >= 0 || client != 0) {
    stellar_smb2_client_destroy(client, 0);
    return 1;
  }
  return 0;
}
