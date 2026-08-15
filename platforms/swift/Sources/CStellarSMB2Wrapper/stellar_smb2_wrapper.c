#define _POSIX_C_SOURCE 200809L

#include "stellar_smb2_wrapper.h"

#include "../CStellarLibsmb2Private/shim.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

struct stellar_smb2_client {
  struct smb2_context *context;
  int connected;
};

static int32_t stellar_smb2_last_status(struct smb2_context *context) {
  int mapped;
  int nt_status;

  nt_status = smb2_get_nterror(context);
  if (nt_status == 0) {
    return -EIO;
  }
  mapped = nterror_to_errno((uint32_t)nt_status);
  if (mapped > 0) {
    return (int32_t)-mapped;
  }
  if (mapped < 0) {
    return (int32_t)mapped;
  }
  return -EIO;
}

static int32_t stellar_smb2_normalize_status(
    struct smb2_context *context, int result) {
  if (result == -1) {
    if (smb2_get_nterror(context) != 0) {
      return stellar_smb2_last_status(context);
    }
    return -EIO;
  }
  return (int32_t)result;
}

static int stellar_smb2_valid_version(uint32_t version) {
  switch (version) {
    case STELLAR_SMB2_VERSION_ANY:
    case STELLAR_SMB2_VERSION_ANY2:
    case STELLAR_SMB2_VERSION_ANY3:
    case STELLAR_SMB2_VERSION_0202:
    case STELLAR_SMB2_VERSION_0210:
    case STELLAR_SMB2_VERSION_0300:
    case STELLAR_SMB2_VERSION_0302:
    case STELLAR_SMB2_VERSION_0311:
      return 1;
    default:
      return 0;
  }
}

static void stellar_smb2_copy_stat(
    const struct smb2_stat_64 *source,
    stellar_smb2_entry_record *destination) {
  destination->type = source->smb2_type;
  destination->size = source->smb2_size;
  destination->modified_seconds = source->smb2_mtime;
  destination->modified_nanoseconds = source->smb2_mtime_nsec;
  destination->inode = source->smb2_ino;
}

int32_t stellar_smb2_client_connect(
    const stellar_smb2_connection_config *config,
    stellar_smb2_client **client_out) {
  stellar_smb2_client *client;
  int result;

  if (config == NULL || client_out == NULL || config->server == NULL ||
      config->share == NULL || config->username == NULL ||
      config->password == NULL || config->timeout_seconds <= 0 ||
      !stellar_smb2_valid_version(config->version)) {
    return -EINVAL;
  }
  *client_out = NULL;

  client = calloc(1, sizeof(*client));
  if (client == NULL) {
    return -ENOMEM;
  }
  client->context = smb2_init_context();
  if (client->context == NULL) {
    free(client);
    return -ENOMEM;
  }

  smb2_set_timeout(client->context, config->timeout_seconds);
  smb2_set_version(client->context, (enum smb2_negotiate_version)config->version);
  smb2_set_security_mode(client->context, config->security_mode);
  smb2_set_sign(client->context, config->require_signing);
  smb2_set_seal(client->context, config->require_encryption);
  smb2_set_authentication(client->context, SMB2_SEC_NTLMSSP);
  if (config->domain != NULL) {
    smb2_set_domain(client->context, config->domain);
  }
  smb2_set_user(client->context, config->username);
  smb2_set_password(client->context, config->password);

  result = smb2_connect_share(
      client->context, config->server, config->share, config->username);
  if (result < 0) {
    int32_t status = stellar_smb2_normalize_status(client->context, result);
    smb2_close_context(client->context);
    smb2_destroy_context(client->context);
    free(client);
    return status;
  }

  client->connected = 1;
  *client_out = client;
  return 0;
}

void stellar_smb2_client_destroy(stellar_smb2_client *client, int graceful) {
  if (client == NULL) {
    return;
  }
  if (graceful && client->connected) {
    (void)smb2_disconnect_share(client->context);
  }
  smb2_close_context(client->context);
  smb2_destroy_context(client->context);
  client->context = NULL;
  client->connected = 0;
  free(client);
}

uint16_t stellar_smb2_client_dialect(const stellar_smb2_client *client) {
  if (client == NULL || client->context == NULL) {
    return 0;
  }
  return smb2_get_dialect(client->context);
}

int32_t stellar_smb2_client_list_directory(
    stellar_smb2_client *client,
    const char *path,
    stellar_smb2_entry_list *list_out) {
  struct smb2dir *directory;
  struct smb2dirent *directory_entry;
  stellar_smb2_entry_record *resized_entries;
  stellar_smb2_entry_record *entry;
  size_t capacity = 0;

  if (client == NULL || client->context == NULL || path == NULL || list_out == NULL) {
    return -EINVAL;
  }
  list_out->entries = NULL;
  list_out->count = 0;

  directory = smb2_opendir(client->context, path);
  if (directory == NULL) {
    return stellar_smb2_last_status(client->context);
  }

  while ((directory_entry = smb2_readdir(client->context, directory)) != NULL) {
    if (directory_entry->name == NULL || strcmp(directory_entry->name, ".") == 0 ||
        strcmp(directory_entry->name, "..") == 0) {
      continue;
    }
    if (list_out->count == capacity) {
      if (capacity > SIZE_MAX / 2 || capacity * 2 > SIZE_MAX / sizeof(*list_out->entries)) {
        smb2_closedir(client->context, directory);
        stellar_smb2_entry_list_destroy(list_out);
        return -EOVERFLOW;
      }
      capacity = capacity == 0 ? 64 : capacity * 2;
      resized_entries = realloc(list_out->entries, capacity * sizeof(*list_out->entries));
      if (resized_entries == NULL) {
        smb2_closedir(client->context, directory);
        stellar_smb2_entry_list_destroy(list_out);
        return -ENOMEM;
      }
      list_out->entries = resized_entries;
    }
    entry = &list_out->entries[list_out->count];
    memset(entry, 0, sizeof(*entry));
    entry->name = strdup(directory_entry->name);
    if (entry->name == NULL) {
      smb2_closedir(client->context, directory);
      stellar_smb2_entry_list_destroy(list_out);
      return -ENOMEM;
    }
    stellar_smb2_copy_stat(&directory_entry->st, entry);
    list_out->count += 1;
  }

  smb2_closedir(client->context, directory);
  return 0;
}

void stellar_smb2_entry_list_destroy(stellar_smb2_entry_list *list) {
  size_t index;

  if (list == NULL) {
    return;
  }
  for (index = 0; index < list->count; index += 1) {
    free(list->entries[index].name);
  }
  free(list->entries);
  list->entries = NULL;
  list->count = 0;
}

int32_t stellar_smb2_client_stat(
    stellar_smb2_client *client,
    const char *path,
    stellar_smb2_entry_record *entry_out) {
  struct smb2_stat_64 entry_stat;
  int result;

  if (client == NULL || client->context == NULL || path == NULL || entry_out == NULL) {
    return -EINVAL;
  }
  memset(entry_out, 0, sizeof(*entry_out));
  memset(&entry_stat, 0, sizeof(entry_stat));
  result = smb2_stat(client->context, path, &entry_stat);
  if (result < 0) {
    return stellar_smb2_normalize_status(client->context, result);
  }
  stellar_smb2_copy_stat(&entry_stat, entry_out);
  return 0;
}

int32_t stellar_smb2_client_read(
    stellar_smb2_client *client,
    const char *path,
    uint64_t offset,
    uint8_t *buffer,
    size_t length,
    size_t *bytes_read_out) {
  struct smb2fh *file;
  size_t total = 0;
  uint32_t maximum_read_size;
  int close_result;
  int read_result = 0;

  if (client == NULL || client->context == NULL || path == NULL || buffer == NULL ||
      length == 0 || bytes_read_out == NULL) {
    return -EINVAL;
  }
  *bytes_read_out = 0;

  file = smb2_open(client->context, path, O_RDONLY);
  if (file == NULL) {
    return stellar_smb2_last_status(client->context);
  }
  maximum_read_size = smb2_get_max_read_size(client->context);
  if (maximum_read_size == 0) {
    maximum_read_size = UINT32_MAX;
  }

  while (total < length) {
    size_t remaining = length - total;
    uint32_t chunk = remaining > maximum_read_size ? maximum_read_size : (uint32_t)remaining;
    if (remaining > UINT32_MAX && maximum_read_size == UINT32_MAX) {
      chunk = UINT32_MAX;
    }
    read_result = smb2_pread(client->context, file, buffer + total, chunk, offset + total);
    if (read_result <= 0) {
      break;
    }
    total += (size_t)read_result;
  }

  close_result = smb2_close(client->context, file);
  if (read_result < 0) {
    return stellar_smb2_normalize_status(client->context, read_result);
  }
  if (close_result < 0) {
    return stellar_smb2_normalize_status(client->context, close_result);
  }
  *bytes_read_out = total;
  return 0;
}
