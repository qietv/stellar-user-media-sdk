#define _POSIX_C_SOURCE 200809L

#include "stellar_smb2_wrapper.h"

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef struct connect_task {
  stellar_smb2_client *client;
  int32_t result;
} connect_task;

static void *run_connect(void *opaque) {
  connect_task *task = opaque;
  task->result = stellar_smb2_client_connect(task->client);
  return NULL;
}

static int64_t elapsed_milliseconds(
    const struct timespec *start, const struct timespec *end) {
  return (int64_t)(end->tv_sec - start->tv_sec) * 1000 +
      (end->tv_nsec - start->tv_nsec) / 1000000;
}

int main(void) {
  struct sockaddr_in address = {0};
  socklen_t address_length = sizeof(address);
  stellar_smb2_client *client = NULL;
  stellar_smb2_connection_config config = {0};
  connect_task task = {0};
  pthread_t thread;
  struct timespec cancel_started;
  struct timespec cancel_finished;
  char server[64];
  int accepted_socket = -1;
  int listener = -1;
  int result = 1;

  alarm(10);
  listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0) {
    goto cleanup;
  }
  address.sin_family = AF_INET;
  if (inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) != 1) {
    goto cleanup;
  }
  address.sin_port = 0;
  if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
      listen(listener, 1) != 0 ||
      getsockname(listener, (struct sockaddr *)&address, &address_length) != 0) {
    goto cleanup;
  }
  if (snprintf(server, sizeof(server), "127.0.0.1:%u", ntohs(address.sin_port)) <= 0) {
    goto cleanup;
  }

  config.server = server;
  config.share = "cancel-smoke";
  config.username = "guest";
  config.password = "";
  config.version = STELLAR_SMB2_VERSION_ANY;
  config.security_mode = 1;
  config.timeout_seconds = 30;
  if (stellar_smb2_client_create(&config, &client) != 0 || client == NULL) {
    goto cleanup;
  }

  task.client = client;
  if (pthread_create(&thread, NULL, run_connect, &task) != 0) {
    goto cleanup;
  }
  accepted_socket = accept(listener, NULL, NULL);
  if (accepted_socket < 0) {
    stellar_smb2_client_cancel(client);
    (void)pthread_join(thread, NULL);
    goto cleanup;
  }

  (void)clock_gettime(CLOCK_MONOTONIC, &cancel_started);
  stellar_smb2_client_cancel(client);
  if (pthread_join(thread, NULL) != 0) {
    goto cleanup;
  }
  (void)clock_gettime(CLOCK_MONOTONIC, &cancel_finished);
  if (task.result != -ECANCELED ||
      elapsed_milliseconds(&cancel_started, &cancel_finished) > 2000) {
    fprintf(
        stderr,
        "in-flight cancellation failed: status=%d elapsed_ms=%lld\n",
        task.result,
        (long long)elapsed_milliseconds(&cancel_started, &cancel_finished));
    goto cleanup;
  }
  result = 0;

cleanup:
  if (client != NULL) {
    stellar_smb2_client_destroy(client, 0);
  }
  if (accepted_socket >= 0) {
    close(accepted_socket);
  }
  if (listener >= 0) {
    close(listener);
  }
  return result;
}
