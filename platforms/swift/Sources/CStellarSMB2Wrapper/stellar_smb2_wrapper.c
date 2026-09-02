#define _POSIX_C_SOURCE 200809L

#include "stellar_smb2_wrapper.h"

#include "../CStellarLibsmb2Private/shim.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#define STELLAR_SMB2_MAX_TRACKED_FDS 64

struct stellar_smb2_directory {
  struct smb2dir *handle;
  size_t entry_count;
  size_t position;
  uint64_t fingerprint;
  struct stellar_smb2_directory *next;
};

struct stellar_smb2_client {
  struct smb2_context *context;
  int connected;
  int cancelled;
  int operation_active;
  int tracked_fds[STELLAR_SMB2_MAX_TRACKED_FDS];
  size_t tracked_fd_count;
  pthread_mutex_t state_lock;
  char *server;
  char *share;
  char *username;
  struct stellar_smb2_directory *directories;
  struct stellar_smb2_client *registry_next;
};

static pthread_mutex_t stellar_smb2_registry_lock = PTHREAD_MUTEX_INITIALIZER;
static stellar_smb2_client *stellar_smb2_registry = NULL;

static void stellar_smb2_registry_add(stellar_smb2_client *client) {
  pthread_mutex_lock(&stellar_smb2_registry_lock);
  client->registry_next = stellar_smb2_registry;
  stellar_smb2_registry = client;
  pthread_mutex_unlock(&stellar_smb2_registry_lock);
}

static void stellar_smb2_registry_remove(stellar_smb2_client *client) {
  stellar_smb2_client **cursor;

  pthread_mutex_lock(&stellar_smb2_registry_lock);
  cursor = &stellar_smb2_registry;
  while (*cursor != NULL) {
    if (*cursor == client) {
      *cursor = client->registry_next;
      client->registry_next = NULL;
      break;
    }
    cursor = &(*cursor)->registry_next;
  }
  pthread_mutex_unlock(&stellar_smb2_registry_lock);
}

static stellar_smb2_client *stellar_smb2_registry_find(
    struct smb2_context *context) {
  stellar_smb2_client *client;

  client = stellar_smb2_registry;
  while (client != NULL && client->context != context) {
    client = client->registry_next;
  }
  return client;
}

static void stellar_smb2_change_fd(
    struct smb2_context *context, t_socket socket_fd, int command) {
  stellar_smb2_client *client;
  size_t index;

  pthread_mutex_lock(&stellar_smb2_registry_lock);
  client = stellar_smb2_registry_find(context);
  if (client == NULL) {
    pthread_mutex_unlock(&stellar_smb2_registry_lock);
    return;
  }

  pthread_mutex_lock(&client->state_lock);
  if (command == SMB2_ADD_FD) {
    for (index = 0; index < client->tracked_fd_count; index += 1) {
      if (client->tracked_fds[index] == (int)socket_fd) {
        break;
      }
    }
    if (index == client->tracked_fd_count &&
        client->tracked_fd_count < STELLAR_SMB2_MAX_TRACKED_FDS) {
      client->tracked_fds[client->tracked_fd_count] = (int)socket_fd;
      client->tracked_fd_count += 1;
    }
    if (client->cancelled) {
      (void)shutdown((int)socket_fd, SHUT_RD);
    }
  } else if (command == SMB2_DEL_FD) {
    for (index = 0; index < client->tracked_fd_count; index += 1) {
      if (client->tracked_fds[index] == (int)socket_fd) {
        client->tracked_fd_count -= 1;
        client->tracked_fds[index] = client->tracked_fds[client->tracked_fd_count];
        break;
      }
    }
  }
  pthread_mutex_unlock(&client->state_lock);
  pthread_mutex_unlock(&stellar_smb2_registry_lock);
}

static int32_t stellar_smb2_operation_begin(
    stellar_smb2_client *client, int require_connected) {
  int32_t result = 0;

  if (client == NULL || client->context == NULL) {
    return -EINVAL;
  }
  pthread_mutex_lock(&client->state_lock);
  if (client->cancelled) {
    result = -ECANCELED;
  } else if (client->operation_active) {
    result = -EBUSY;
  } else if (require_connected && !client->connected) {
    result = -ENOTCONN;
  } else {
    client->operation_active = 1;
  }
  pthread_mutex_unlock(&client->state_lock);
  return result;
}

static int stellar_smb2_client_is_cancelled(stellar_smb2_client *client) {
  int cancelled;

  pthread_mutex_lock(&client->state_lock);
  cancelled = client->cancelled;
  pthread_mutex_unlock(&client->state_lock);
  return cancelled;
}

static int32_t stellar_smb2_operation_end(
    stellar_smb2_client *client, int32_t result) {
  int cancelled;

  pthread_mutex_lock(&client->state_lock);
  cancelled = client->cancelled;
  client->operation_active = 0;
  pthread_mutex_unlock(&client->state_lock);
  return cancelled ? -ECANCELED : result;
}

static int stellar_smb2_is_authentication_status(uint32_t status) {
  switch (status) {
    case SMB2_STATUS_INVALID_ACCOUNT_NAME:
    case SMB2_STATUS_NO_SUCH_USER:
    case SMB2_STATUS_WRONG_PASSWORD:
    case SMB2_STATUS_ILL_FORMED_PASSWORD:
    case SMB2_STATUS_PASSWORD_RESTRICTION:
    case SMB2_STATUS_LOGON_FAILURE:
    case SMB2_STATUS_ACCOUNT_RESTRICTION:
    case SMB2_STATUS_INVALID_LOGON_HOURS:
    case SMB2_STATUS_INVALID_WORKSTATION:
    case SMB2_STATUS_PASSWORD_EXPIRED:
    case SMB2_STATUS_ACCOUNT_DISABLED:
    case SMB2_STATUS_WRONG_PASSWORD_CORE:
    case SMB2_STATUS_PASSWORD_MUST_CHANGE:
    case SMB2_STATUS_ACCOUNT_LOCKED_OUT:
      return 1;
    default:
      return 0;
  }
}

static int32_t stellar_smb2_last_status(struct smb2_context *context) {
  int mapped;
  int nt_status;

  nt_status = smb2_get_nterror(context);
  if (nt_status == 0) {
    return -EIO;
  }
  if (stellar_smb2_is_authentication_status((uint32_t)nt_status)) {
    return -EACCES;
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

static int stellar_smb2_directory_entry_is_visible(
    const struct smb2dirent *entry) {
  return entry != NULL && entry->name != NULL &&
      strcmp(entry->name, ".") != 0 && strcmp(entry->name, "..") != 0;
}

static void stellar_smb2_fingerprint_byte(uint64_t *hash, uint8_t byte) {
  *hash ^= byte;
  *hash *= UINT64_C(1099511628211);
}

static void stellar_smb2_fingerprint_uint64(uint64_t *hash, uint64_t value) {
  unsigned int shift;

  for (shift = 0; shift < 64; shift += 8) {
    stellar_smb2_fingerprint_byte(hash, (uint8_t)(value >> shift));
  }
}

static void stellar_smb2_fingerprint_entry(
    uint64_t *hash, const struct smb2dirent *entry) {
  const unsigned char *name = (const unsigned char *)entry->name;

  while (*name != 0) {
    stellar_smb2_fingerprint_byte(hash, *name);
    name += 1;
  }
  stellar_smb2_fingerprint_byte(hash, 0xff);
  stellar_smb2_fingerprint_uint64(hash, entry->st.smb2_type);
  stellar_smb2_fingerprint_uint64(hash, entry->st.smb2_size);
  stellar_smb2_fingerprint_uint64(hash, entry->st.smb2_mtime);
  stellar_smb2_fingerprint_uint64(hash, entry->st.smb2_mtime_nsec);
  stellar_smb2_fingerprint_uint64(hash, entry->st.smb2_ino);
}

static int stellar_smb2_directory_is_tracked(
    stellar_smb2_client *client, stellar_smb2_directory *directory) {
  stellar_smb2_directory *cursor;

  cursor = client->directories;
  while (cursor != NULL && cursor != directory) {
    cursor = cursor->next;
  }
  return cursor != NULL;
}

static void stellar_smb2_close_all_directories(stellar_smb2_client *client) {
  stellar_smb2_directory *directory;

  while (client->directories != NULL) {
    directory = client->directories;
    client->directories = directory->next;
    smb2_closedir(client->context, directory->handle);
    free(directory);
  }
}

int32_t stellar_smb2_client_create(
    const stellar_smb2_connection_config *config,
    stellar_smb2_client **client_out) {
  stellar_smb2_client *client;
  int mutex_result;

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
  mutex_result = pthread_mutex_init(&client->state_lock, NULL);
  if (mutex_result != 0) {
    free(client);
    return (int32_t)-mutex_result;
  }
  client->server = strdup(config->server);
  client->share = strdup(config->share);
  client->username = strdup(config->username);
  if (client->server == NULL || client->share == NULL || client->username == NULL) {
    free(client->username);
    free(client->share);
    free(client->server);
    pthread_mutex_destroy(&client->state_lock);
    free(client);
    return -ENOMEM;
  }
  client->context = smb2_init_context();
  if (client->context == NULL) {
    free(client->username);
    free(client->share);
    free(client->server);
    pthread_mutex_destroy(&client->state_lock);
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
  smb2_fd_event_callbacks(client->context, stellar_smb2_change_fd, NULL);
  stellar_smb2_registry_add(client);

  *client_out = client;
  return 0;
}

int32_t stellar_smb2_client_connect(stellar_smb2_client *client) {
  int32_t begin_result;
  int result;

  begin_result = stellar_smb2_operation_begin(client, 0);
  if (begin_result != 0) {
    return begin_result;
  }

  result = smb2_connect_share(
      client->context, client->server, client->share, client->username);
  if (result < 0) {
    int32_t status = stellar_smb2_normalize_status(client->context, result);
    return stellar_smb2_operation_end(client, status);
  }

  pthread_mutex_lock(&client->state_lock);
  if (!client->cancelled) {
    client->connected = 1;
  }
  pthread_mutex_unlock(&client->state_lock);
  return stellar_smb2_operation_end(client, 0);
}

void stellar_smb2_client_cancel(stellar_smb2_client *client) {
  size_t index;

  if (client == NULL) {
    return;
  }
  pthread_mutex_lock(&client->state_lock);
  client->cancelled = 1;
  for (index = 0; index < client->tracked_fd_count; index += 1) {
    (void)shutdown(client->tracked_fds[index], SHUT_RD);
  }
  pthread_mutex_unlock(&client->state_lock);
}

void stellar_smb2_client_destroy(stellar_smb2_client *client, int graceful) {
  if (client == NULL) {
    return;
  }
  stellar_smb2_close_all_directories(client);
  if (graceful && client->connected && !client->cancelled) {
    (void)smb2_disconnect_share(client->context);
  }
  stellar_smb2_registry_remove(client);
  smb2_close_context(client->context);
  smb2_destroy_context(client->context);
  client->context = NULL;
  client->connected = 0;
  free(client->username);
  free(client->share);
  free(client->server);
  pthread_mutex_destroy(&client->state_lock);
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
  int32_t begin_result;
  int32_t status = 0;

  if (client == NULL || client->context == NULL || path == NULL || list_out == NULL) {
    return -EINVAL;
  }
  list_out->entries = NULL;
  list_out->count = 0;
  begin_result = stellar_smb2_operation_begin(client, 1);
  if (begin_result != 0) {
    return begin_result;
  }

  directory = smb2_opendir(client->context, path);
  if (directory == NULL) {
    status = stellar_smb2_last_status(client->context);
    return stellar_smb2_operation_end(client, status);
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
        return stellar_smb2_operation_end(client, -EOVERFLOW);
      }
      capacity = capacity == 0 ? 64 : capacity * 2;
      resized_entries = realloc(list_out->entries, capacity * sizeof(*list_out->entries));
      if (resized_entries == NULL) {
        smb2_closedir(client->context, directory);
        stellar_smb2_entry_list_destroy(list_out);
        return stellar_smb2_operation_end(client, -ENOMEM);
      }
      list_out->entries = resized_entries;
    }
    entry = &list_out->entries[list_out->count];
    memset(entry, 0, sizeof(*entry));
    entry->name = strdup(directory_entry->name);
    if (entry->name == NULL) {
      smb2_closedir(client->context, directory);
      stellar_smb2_entry_list_destroy(list_out);
      return stellar_smb2_operation_end(client, -ENOMEM);
    }
    stellar_smb2_copy_stat(&directory_entry->st, entry);
    list_out->count += 1;
  }

  if (stellar_smb2_client_is_cancelled(client)) {
    stellar_smb2_entry_list_destroy(list_out);
  } else {
    smb2_closedir(client->context, directory);
  }
  return stellar_smb2_operation_end(client, 0);
}

int32_t stellar_smb2_client_open_directory(
    stellar_smb2_client *client,
    const char *path,
    stellar_smb2_directory **directory_out,
    uint64_t *fingerprint_out,
    size_t *entry_count_out) {
  stellar_smb2_directory *directory;
  struct smb2dir *handle;
  struct smb2dirent *entry;
  uint64_t fingerprint = UINT64_C(14695981039346656037);
  size_t entry_count = 0;
  int32_t begin_result;
  int32_t result;

  if (client == NULL || client->context == NULL || path == NULL ||
      directory_out == NULL || fingerprint_out == NULL || entry_count_out == NULL) {
    return -EINVAL;
  }
  *directory_out = NULL;
  *fingerprint_out = 0;
  *entry_count_out = 0;
  begin_result = stellar_smb2_operation_begin(client, 1);
  if (begin_result != 0) {
    return begin_result;
  }

  handle = smb2_opendir(client->context, path);
  if (handle == NULL) {
    return stellar_smb2_operation_end(
        client, stellar_smb2_last_status(client->context));
  }
  while ((entry = smb2_readdir(client->context, handle)) != NULL) {
    if (!stellar_smb2_directory_entry_is_visible(entry)) {
      continue;
    }
    if (entry_count == SIZE_MAX) {
      smb2_closedir(client->context, handle);
      return stellar_smb2_operation_end(client, -EOVERFLOW);
    }
    stellar_smb2_fingerprint_entry(&fingerprint, entry);
    entry_count += 1;
  }
  smb2_rewinddir(client->context, handle);

  directory = calloc(1, sizeof(*directory));
  if (directory == NULL) {
    smb2_closedir(client->context, handle);
    return stellar_smb2_operation_end(client, -ENOMEM);
  }
  directory->handle = handle;
  directory->entry_count = entry_count;
  directory->fingerprint = fingerprint;

  pthread_mutex_lock(&client->state_lock);
  directory->next = client->directories;
  client->directories = directory;
  pthread_mutex_unlock(&client->state_lock);

  result = stellar_smb2_operation_end(client, 0);
  if (result != 0) {
    stellar_smb2_client_close_directory(client, directory);
    return result;
  }
  *directory_out = directory;
  *fingerprint_out = fingerprint;
  *entry_count_out = entry_count;
  return 0;
}

int32_t stellar_smb2_client_read_directory(
    stellar_smb2_client *client,
    stellar_smb2_directory *directory,
    size_t limit,
    stellar_smb2_entry_list *list_out,
    int *has_more_out) {
  struct smb2dirent *directory_entry;
  stellar_smb2_entry_record *entry;
  size_t batch_count;
  int32_t begin_result;
  int32_t result;

  if (client == NULL || client->context == NULL || directory == NULL ||
      limit == 0 || list_out == NULL || has_more_out == NULL) {
    return -EINVAL;
  }
  list_out->entries = NULL;
  list_out->count = 0;
  *has_more_out = 0;
  begin_result = stellar_smb2_operation_begin(client, 1);
  if (begin_result != 0) {
    return begin_result;
  }

  pthread_mutex_lock(&client->state_lock);
  result = stellar_smb2_directory_is_tracked(client, directory) ? 0 : -EINVAL;
  pthread_mutex_unlock(&client->state_lock);
  if (result != 0) {
    return stellar_smb2_operation_end(client, result);
  }

  batch_count = directory->entry_count - directory->position;
  if (batch_count > limit) {
    batch_count = limit;
  }
  if (batch_count > SIZE_MAX / sizeof(*list_out->entries)) {
    return stellar_smb2_operation_end(client, -EOVERFLOW);
  }
  if (batch_count > 0) {
    list_out->entries = calloc(batch_count, sizeof(*list_out->entries));
    if (list_out->entries == NULL) {
      return stellar_smb2_operation_end(client, -ENOMEM);
    }
  }

  while (list_out->count < batch_count) {
    directory_entry = smb2_readdir(client->context, directory->handle);
    if (directory_entry == NULL) {
      stellar_smb2_entry_list_destroy(list_out);
      return stellar_smb2_operation_end(client, -EIO);
    }
    if (!stellar_smb2_directory_entry_is_visible(directory_entry)) {
      continue;
    }
    entry = &list_out->entries[list_out->count];
    entry->name = strdup(directory_entry->name);
    if (entry->name == NULL) {
      stellar_smb2_entry_list_destroy(list_out);
      return stellar_smb2_operation_end(client, -ENOMEM);
    }
    stellar_smb2_copy_stat(&directory_entry->st, entry);
    list_out->count += 1;
    directory->position += 1;
  }
  *has_more_out = directory->position < directory->entry_count;
  result = stellar_smb2_operation_end(client, 0);
  if (result != 0) {
    stellar_smb2_entry_list_destroy(list_out);
    *has_more_out = 0;
  }
  return result;
}

void stellar_smb2_client_close_directory(
    stellar_smb2_client *client,
    stellar_smb2_directory *directory) {
  stellar_smb2_directory **cursor;
  int found = 0;

  if (client == NULL || client->context == NULL || directory == NULL) {
    return;
  }
  pthread_mutex_lock(&client->state_lock);
  cursor = &client->directories;
  while (*cursor != NULL) {
    if (*cursor == directory) {
      *cursor = directory->next;
      found = 1;
      break;
    }
    cursor = &(*cursor)->next;
  }
  pthread_mutex_unlock(&client->state_lock);
  if (!found) {
    return;
  }
  smb2_closedir(client->context, directory->handle);
  free(directory);
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
  int32_t begin_result;
  int result;

  if (client == NULL || client->context == NULL || path == NULL || entry_out == NULL) {
    return -EINVAL;
  }
  memset(entry_out, 0, sizeof(*entry_out));
  memset(&entry_stat, 0, sizeof(entry_stat));
  begin_result = stellar_smb2_operation_begin(client, 1);
  if (begin_result != 0) {
    return begin_result;
  }
  result = smb2_stat(client->context, path, &entry_stat);
  if (result < 0) {
    return stellar_smb2_operation_end(
        client, stellar_smb2_normalize_status(client->context, result));
  }
  stellar_smb2_copy_stat(&entry_stat, entry_out);
  return stellar_smb2_operation_end(client, 0);
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
  int32_t begin_result;
  int close_result;
  int read_result = 0;

  if (client == NULL || client->context == NULL || path == NULL || buffer == NULL ||
      length == 0 || bytes_read_out == NULL) {
    return -EINVAL;
  }
  *bytes_read_out = 0;
  begin_result = stellar_smb2_operation_begin(client, 1);
  if (begin_result != 0) {
    return begin_result;
  }

  file = smb2_open(client->context, path, O_RDONLY);
  if (file == NULL) {
    return stellar_smb2_operation_end(client, stellar_smb2_last_status(client->context));
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

  close_result = stellar_smb2_client_is_cancelled(client)
      ? 0
      : smb2_close(client->context, file);
  if (read_result < 0) {
    return stellar_smb2_operation_end(
        client, stellar_smb2_normalize_status(client->context, read_result));
  }
  if (close_result < 0) {
    return stellar_smb2_operation_end(
        client, stellar_smb2_normalize_status(client->context, close_result));
  }
  *bytes_read_out = total;
  return stellar_smb2_operation_end(client, 0);
}
