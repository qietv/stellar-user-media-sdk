#ifndef C_STELLAR_FFMPEG_SCREENSHOT_H
#define C_STELLAR_FFMPEG_SCREENSHOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct StellarFFmpegCaptureContext StellarFFmpegCaptureContext;

typedef struct StellarFFmpegDecodedFrame {
  uint8_t *bytes;
  size_t byte_count;
  int32_t width;
  int32_t height;
  int32_t bytes_per_row;
} StellarFFmpegDecodedFrame;

enum {
  STELLAR_FFMPEG_CAPTURE_OK = 0,
  STELLAR_FFMPEG_CAPTURE_CANCELLED = -70001,
  STELLAR_FFMPEG_CAPTURE_NO_VIDEO = -70002,
  STELLAR_FFMPEG_CAPTURE_NO_FRAME = -70003,
  STELLAR_FFMPEG_CAPTURE_INVALID_ARGUMENT = -70004,
  STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED = -70005,
  STELLAR_FFMPEG_CAPTURE_CONVERSION_FAILED = -70006,
};

StellarFFmpegCaptureContext *stellar_ffmpeg_capture_context_create(void);
void stellar_ffmpeg_capture_context_cancel(StellarFFmpegCaptureContext *context);
void stellar_ffmpeg_capture_context_destroy(StellarFFmpegCaptureContext *context);

/// Decodes the first video frame at or after `timestamp_milliseconds` into BGRA8.
/// A `maximum_pixel_dimension` of zero preserves the decoded pixel dimensions.
int32_t stellar_ffmpeg_capture_frame(
    StellarFFmpegCaptureContext *context,
    const char *file_path,
    int64_t timestamp_milliseconds,
    int32_t maximum_pixel_dimension,
    StellarFFmpegDecodedFrame *output);

void stellar_ffmpeg_decoded_frame_destroy(StellarFFmpegDecodedFrame *frame);

#ifdef __cplusplus
}
#endif

#endif
