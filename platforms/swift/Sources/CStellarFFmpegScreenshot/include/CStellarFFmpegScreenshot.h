#ifndef C_STELLAR_FFMPEG_SCREENSHOT_H
#define C_STELLAR_FFMPEG_SCREENSHOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct StellarFFmpegCaptureContext StellarFFmpegCaptureContext;

/// Synchronous random-access callbacks used by libavformat custom AVIO.
/// `read` returns bytes copied, zero at EOF, or a negative value on failure.
/// `seek` follows SEEK_SET/SEEK_CUR/SEEK_END and AVSEEK_SIZE semantics.
typedef int32_t (*StellarFFmpegReadCallback)(
    void *opaque,
    uint8_t *buffer,
    int32_t buffer_size);
typedef int64_t (*StellarFFmpegSeekCallback)(
    void *opaque,
    int64_t offset,
    int32_t whence);

typedef struct StellarFFmpegDecodedFrame {
  uint8_t *bytes;
  size_t byte_count;
  int32_t width;
  int32_t height;
  int32_t bytes_per_row;
} StellarFFmpegDecodedFrame;

enum {
  STELLAR_FFMPEG_STREAM_VIDEO = 1,
  STELLAR_FFMPEG_STREAM_AUDIO = 2,
  STELLAR_FFMPEG_STREAM_SUBTITLE = 3,
  STELLAR_FFMPEG_STREAM_ATTACHMENT = 4,
};

typedef struct StellarFFmpegTechnicalStream {
  int32_t stream_index;
  int32_t kind;
  char *codec;
  char *language;
  char *title;
  int64_t bit_rate;
  int32_t width;
  int32_t height;
  double frame_rate;
  char *hdr_profile;
  double channel_count;
  char *channel_layout;
  int32_t sample_rate;
  bool is_default;
  bool is_forced;
} StellarFFmpegTechnicalStream;

typedef struct StellarFFmpegTechnicalProbe {
  char *container;
  int64_t duration_milliseconds;
  int64_t overall_bit_rate;
  char *video_codec;
  int32_t width;
  int32_t height;
  double frame_rate;
  char *hdr_profile;
  char *audio_codec;
  double audio_channels;
  bool has_embedded_cover;
  StellarFFmpegTechnicalStream *streams;
  int32_t stream_count;
} StellarFFmpegTechnicalProbe;

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

/// Decodes through caller-owned seekable range I/O without materializing the source file.
/// `filename_hint` is used only for format detection and must not contain credentials.
int32_t stellar_ffmpeg_capture_frame_with_io(
    StellarFFmpegCaptureContext *context,
    void *opaque,
    StellarFFmpegReadCallback read_callback,
    StellarFFmpegSeekCallback seek_callback,
    const char *filename_hint,
    int64_t timestamp_milliseconds,
    int32_t maximum_pixel_dimension,
    StellarFFmpegDecodedFrame *output);

/// Inspects container and stream metadata through the same seekable range bridge.
int32_t stellar_ffmpeg_probe_with_io(
    StellarFFmpegCaptureContext *context,
    void *opaque,
    StellarFFmpegReadCallback read_callback,
    StellarFFmpegSeekCallback seek_callback,
    const char *filename_hint,
    StellarFFmpegTechnicalProbe *output);

void stellar_ffmpeg_decoded_frame_destroy(StellarFFmpegDecodedFrame *frame);
void stellar_ffmpeg_technical_probe_destroy(StellarFFmpegTechnicalProbe *probe);

#ifdef __cplusplus
}
#endif

#endif
