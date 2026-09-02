#include "CStellarFFmpegScreenshot.h"

#include <Libavcodec/avcodec.h>
#include <Libavformat/avformat.h>
#include <Libavutil/avutil.h>
#include <Libavutil/mem.h>
#include <Libavutil/pixfmt.h>
#include <Libavutil/rational.h>
#include <Libswscale/swscale.h>

#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct StellarFFmpegCaptureContext {
  atomic_bool cancelled;
};

static int stellar_ffmpeg_interrupt(void *opaque) {
  StellarFFmpegCaptureContext *context = opaque;
  return context != NULL && atomic_load_explicit(&context->cancelled, memory_order_relaxed);
}

static bool stellar_ffmpeg_is_cancelled(StellarFFmpegCaptureContext *context) {
  return context != NULL && atomic_load_explicit(&context->cancelled, memory_order_relaxed);
}

StellarFFmpegCaptureContext *stellar_ffmpeg_capture_context_create(void) {
  StellarFFmpegCaptureContext *context = calloc(1, sizeof(*context));
  if (context != NULL) {
    atomic_init(&context->cancelled, false);
  }
  return context;
}

void stellar_ffmpeg_capture_context_cancel(StellarFFmpegCaptureContext *context) {
  if (context != NULL) {
    atomic_store_explicit(&context->cancelled, true, memory_order_relaxed);
  }
}

void stellar_ffmpeg_capture_context_destroy(StellarFFmpegCaptureContext *context) {
  free(context);
}

void stellar_ffmpeg_decoded_frame_destroy(StellarFFmpegDecodedFrame *frame) {
  if (frame == NULL) {
    return;
  }
  av_freep(&frame->bytes);
  memset(frame, 0, sizeof(*frame));
}

static int32_t stellar_ffmpeg_copy_frame(
    const AVFrame *source,
    int32_t maximum_pixel_dimension,
    StellarFFmpegDecodedFrame *output) {
  if (source == NULL || source->width <= 0 || source->height <= 0 || output == NULL) {
    return STELLAR_FFMPEG_CAPTURE_INVALID_ARGUMENT;
  }

  int destination_width = source->width;
  int destination_height = source->height;
  int source_maximum = source->width > source->height ? source->width : source->height;
  if (maximum_pixel_dimension > 0 && source_maximum > maximum_pixel_dimension) {
    destination_width = (int)(((int64_t)source->width * maximum_pixel_dimension + source_maximum / 2) / source_maximum);
    destination_height = (int)(((int64_t)source->height * maximum_pixel_dimension + source_maximum / 2) / source_maximum);
    if (destination_width < 1) {
      destination_width = 1;
    }
    if (destination_height < 1) {
      destination_height = 1;
    }
  }

  if (destination_width > INT_MAX / 4) {
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }
  int destination_stride = destination_width * 4;
  if ((size_t)destination_height > SIZE_MAX / (size_t)destination_stride) {
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }
  size_t destination_size = (size_t)destination_stride * (size_t)destination_height;
  if (destination_size > (size_t)1024 * 1024 * 1024) {
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }
  uint8_t *destination = av_malloc(destination_size);
  if (destination == NULL) {
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }

  struct SwsContext *scale_context = sws_getContext(
      source->width,
      source->height,
      (enum AVPixelFormat)source->format,
      destination_width,
      destination_height,
      AV_PIX_FMT_BGRA,
      SWS_BILINEAR,
      NULL,
      NULL,
      NULL);
  if (scale_context == NULL) {
    av_free(destination);
    return STELLAR_FFMPEG_CAPTURE_CONVERSION_FAILED;
  }

  uint8_t *destination_planes[4] = {destination, NULL, NULL, NULL};
  int destination_strides[4] = {destination_stride, 0, 0, 0};
  int rows = sws_scale(
      scale_context,
      (const uint8_t *const *)source->data,
      source->linesize,
      0,
      source->height,
      destination_planes,
      destination_strides);
  sws_freeContext(scale_context);
  if (rows != destination_height) {
    av_free(destination);
    return STELLAR_FFMPEG_CAPTURE_CONVERSION_FAILED;
  }

  output->bytes = destination;
  output->byte_count = destination_size;
  output->width = destination_width;
  output->height = destination_height;
  output->bytes_per_row = destination_stride;
  return STELLAR_FFMPEG_CAPTURE_OK;
}

static int32_t stellar_ffmpeg_receive_frame(
    StellarFFmpegCaptureContext *capture_context,
    AVCodecContext *decoder_context,
    AVFrame *frame,
    int64_t target_timestamp,
    int32_t maximum_pixel_dimension,
    StellarFFmpegDecodedFrame *output) {
  while (true) {
    if (stellar_ffmpeg_is_cancelled(capture_context)) {
      return STELLAR_FFMPEG_CAPTURE_CANCELLED;
    }
    int result = avcodec_receive_frame(decoder_context, frame);
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
      return result;
    }
    if (result < 0) {
      return result;
    }

    int64_t timestamp = frame->best_effort_timestamp;
    if (target_timestamp <= 0 || timestamp == AV_NOPTS_VALUE || timestamp >= target_timestamp) {
      return stellar_ffmpeg_copy_frame(frame, maximum_pixel_dimension, output);
    }
    av_frame_unref(frame);
  }
}

int32_t stellar_ffmpeg_capture_frame(
    StellarFFmpegCaptureContext *context,
    const char *file_path,
    int64_t timestamp_milliseconds,
    int32_t maximum_pixel_dimension,
    StellarFFmpegDecodedFrame *output) {
  if (context == NULL || file_path == NULL || file_path[0] == '\0' || output == NULL ||
      timestamp_milliseconds < 0 || maximum_pixel_dimension < 0) {
    return STELLAR_FFMPEG_CAPTURE_INVALID_ARGUMENT;
  }
  memset(output, 0, sizeof(*output));
  if (stellar_ffmpeg_is_cancelled(context)) {
    return STELLAR_FFMPEG_CAPTURE_CANCELLED;
  }

  int32_t capture_result = STELLAR_FFMPEG_CAPTURE_NO_FRAME;
  AVFormatContext *format_context = avformat_alloc_context();
  AVCodecContext *decoder_context = NULL;
  AVPacket *packet = NULL;
  AVFrame *frame = NULL;
  if (format_context == NULL) {
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }
  format_context->interrupt_callback.callback = stellar_ffmpeg_interrupt;
  format_context->interrupt_callback.opaque = context;

  int result = avformat_open_input(&format_context, file_path, NULL, NULL);
  if (result < 0) {
    capture_result = result;
    goto cleanup;
  }
  result = avformat_find_stream_info(format_context, NULL);
  if (result < 0) {
    capture_result = result;
    goto cleanup;
  }

  const AVCodec *decoder = NULL;
  int video_stream_index = av_find_best_stream(
      format_context, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0);
  if (video_stream_index < 0 || decoder == NULL) {
    capture_result = STELLAR_FFMPEG_CAPTURE_NO_VIDEO;
    goto cleanup;
  }
  AVStream *video_stream = format_context->streams[video_stream_index];
  decoder_context = avcodec_alloc_context3(decoder);
  if (decoder_context == NULL) {
    capture_result = STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
    goto cleanup;
  }
  result = avcodec_parameters_to_context(decoder_context, video_stream->codecpar);
  if (result < 0) {
    capture_result = result;
    goto cleanup;
  }
  decoder_context->pkt_timebase = video_stream->time_base;
  result = avcodec_open2(decoder_context, decoder, NULL);
  if (result < 0) {
    capture_result = result;
    goto cleanup;
  }

  int64_t target_timestamp = av_rescale_q(
      timestamp_milliseconds,
      (AVRational){1, 1000},
      video_stream->time_base);
  if (video_stream->start_time != AV_NOPTS_VALUE) {
    target_timestamp += video_stream->start_time;
  }
  if (target_timestamp > 0) {
    result = av_seek_frame(format_context, video_stream_index, target_timestamp, AVSEEK_FLAG_BACKWARD);
    if (result >= 0) {
      avcodec_flush_buffers(decoder_context);
    }
  }

  packet = av_packet_alloc();
  frame = av_frame_alloc();
  if (packet == NULL || frame == NULL) {
    capture_result = STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
    goto cleanup;
  }

  while (!stellar_ffmpeg_is_cancelled(context) && av_read_frame(format_context, packet) >= 0) {
    if (packet->stream_index == video_stream_index) {
      result = avcodec_send_packet(decoder_context, packet);
      if (result >= 0 || result == AVERROR(EAGAIN)) {
        result = stellar_ffmpeg_receive_frame(
            context,
            decoder_context,
            frame,
            target_timestamp,
            maximum_pixel_dimension,
            output);
        if (result == STELLAR_FFMPEG_CAPTURE_OK ||
            (result < 0 && result != AVERROR(EAGAIN) && result != AVERROR_EOF)) {
          capture_result = result;
          av_packet_unref(packet);
          goto cleanup;
        }
      } else {
        capture_result = result;
        av_packet_unref(packet);
        goto cleanup;
      }
    }
    av_packet_unref(packet);
  }

  if (stellar_ffmpeg_is_cancelled(context)) {
    capture_result = STELLAR_FFMPEG_CAPTURE_CANCELLED;
    goto cleanup;
  }

  result = avcodec_send_packet(decoder_context, NULL);
  if (result >= 0 || result == AVERROR_EOF) {
    result = stellar_ffmpeg_receive_frame(
        context,
        decoder_context,
        frame,
        target_timestamp,
        maximum_pixel_dimension,
        output);
    if (result == STELLAR_FFMPEG_CAPTURE_OK) {
      capture_result = result;
    } else if (result < 0 && result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
      capture_result = result;
    }
  } else {
    capture_result = result;
  }

cleanup:
  if (stellar_ffmpeg_is_cancelled(context)) {
    capture_result = STELLAR_FFMPEG_CAPTURE_CANCELLED;
  }
  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&decoder_context);
  avformat_close_input(&format_context);
  if (capture_result != STELLAR_FFMPEG_CAPTURE_OK) {
    stellar_ffmpeg_decoded_frame_destroy(output);
  }
  return capture_result;
}
