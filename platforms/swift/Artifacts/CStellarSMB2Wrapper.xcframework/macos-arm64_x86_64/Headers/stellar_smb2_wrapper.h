#ifndef STELLAR_SMB2_WRAPPER_H
#define STELLAR_SMB2_WRAPPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct stellar_smb2_client stellar_smb2_client;
typedef struct stellar_smb2_directory stellar_smb2_directory;

enum stellar_smb2_version {
  STELLAR_SMB2_VERSION_ANY = 0,
  STELLAR_SMB2_VERSION_ANY2 = 2,
  STELLAR_SMB2_VERSION_ANY3 = 3,
  STELLAR_SMB2_VERSION_0202 = 0x0202,
  STELLAR_SMB2_VERSION_0210 = 0x0210,
  STELLAR_SMB2_VERSION_0300 = 0x0300,
  STELLAR_SMB2_VERSION_0302 = 0x0302,
  STELLAR_SMB2_VERSION_0311 = 0x0311,
};

enum stellar_smb2_entry_type {
  STELLAR_SMB2_ENTRY_FILE = 0,
  STELLAR_SMB2_ENTRY_DIRECTORY = 1,
  STELLAR_SMB2_ENTRY_LINK = 2,
};

typedef struct stellar_smb2_connection_config {
  const char *server;
  const char *share;
  const char *domain;
  const char *username;
  const char *password;
  uint32_t version;
  uint16_t security_mode;
  int require_signing;
  int require_encryption;
  int32_t timeout_seconds;
} stellar_smb2_connection_config;

typedef struct stellar_smb2_entry_record {
  char *name;
  uint32_t type;
  uint64_t size;
  uint64_t modified_seconds;
  uint64_t modified_nanoseconds;
  uint64_t inode;
} stellar_smb2_entry_record;

typedef struct stellar_smb2_entry_list {
  stellar_smb2_entry_record *entries;
  size_t count;
} stellar_smb2_entry_list;

int32_t stellar_smb2_client_create(
    const stellar_smb2_connection_config *config,
    stellar_smb2_client **client_out);

int32_t stellar_smb2_client_connect(stellar_smb2_client *client);

/*
 * Thread-safe and idempotent. Interrupts the active synchronous call without
 * destroying its libsmb2 context on the cancelling thread. Cancellation is
 * sticky: destroy the client after the interrupted call has returned.
 */
void stellar_smb2_client_cancel(stellar_smb2_client *client);

void stellar_smb2_client_destroy(stellar_smb2_client *client, int graceful);

uint16_t stellar_smb2_client_dialect(const stellar_smb2_client *client);

int32_t stellar_smb2_client_list_directory(
    stellar_smb2_client *client,
    const char *path,
    stellar_smb2_entry_list *list_out);

int32_t stellar_smb2_client_open_directory(
    stellar_smb2_client *client,
    const char *path,
    stellar_smb2_directory **directory_out,
    uint64_t *fingerprint_out,
    size_t *entry_count_out);

int32_t stellar_smb2_client_read_directory(
    stellar_smb2_client *client,
    stellar_smb2_directory *directory,
    size_t limit,
    stellar_smb2_entry_list *list_out,
    int *has_more_out);

void stellar_smb2_client_close_directory(
    stellar_smb2_client *client,
    stellar_smb2_directory *directory);

void stellar_smb2_entry_list_destroy(stellar_smb2_entry_list *list);

int32_t stellar_smb2_client_stat(
    stellar_smb2_client *client,
    const char *path,
    stellar_smb2_entry_record *entry_out);

int32_t stellar_smb2_client_read(
    stellar_smb2_client *client,
    const char *path,
    uint64_t offset,
    uint8_t *buffer,
    size_t length,
    size_t *bytes_read_out);

#ifdef __cplusplus
}
#endif

#endif
