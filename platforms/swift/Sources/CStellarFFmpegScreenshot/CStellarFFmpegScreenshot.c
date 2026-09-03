#include "CStellarFFmpegScreenshot.h"

#include <Libavcodec/avcodec.h>
#include <Libavformat/avformat.h>
#include <Libavutil/avutil.h>
#include <Libavutil/channel_layout.h>
#include <Libavutil/dict.h>
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

void stellar_ffmpeg_technical_probe_destroy(StellarFFmpegTechnicalProbe *probe) {
  if (probe == NULL) {
    return;
  }
  av_freep(&probe->container);
  av_freep(&probe->video_codec);
  av_freep(&probe->hdr_profile);
  av_freep(&probe->audio_codec);
  if (probe->streams != NULL) {
    for (int32_t index = 0; index < probe->stream_count; index++) {
      StellarFFmpegTechnicalStream *stream = &probe->streams[index];
      av_freep(&stream->codec);
      av_freep(&stream->language);
      av_freep(&stream->title);
      av_freep(&stream->hdr_profile);
      av_freep(&stream->channel_layout);
    }
  }
  av_freep(&probe->streams);
  memset(probe, 0, sizeof(*probe));
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

static int32_t stellar_ffmpeg_capture_opened_input(
    StellarFFmpegCaptureContext *context,
    AVFormatContext *format_context,
    int64_t timestamp_milliseconds,
    int32_t maximum_pixel_dimension,
    StellarFFmpegDecodedFrame *output) {
  int32_t capture_result = STELLAR_FFMPEG_CAPTURE_NO_FRAME;
  AVCodecContext *decoder_context = NULL;
  AVPacket *packet = NULL;
  AVFrame *frame = NULL;
  int result = avformat_find_stream_info(format_context, NULL);
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
  return capture_result;
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

  AVFormatContext *format_context = avformat_alloc_context();
  if (format_context == NULL) {
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }
  format_context->interrupt_callback.callback = stellar_ffmpeg_interrupt;
  format_context->interrupt_callback.opaque = context;

  int32_t capture_result = avformat_open_input(&format_context, file_path, NULL, NULL);
  if (capture_result >= 0) {
    capture_result = stellar_ffmpeg_capture_opened_input(
        context,
        format_context,
        timestamp_milliseconds,
        maximum_pixel_dimension,
        output);
  }
  avformat_close_input(&format_context);
  if (capture_result != STELLAR_FFMPEG_CAPTURE_OK) {
    stellar_ffmpeg_decoded_frame_destroy(output);
  }
  return capture_result;
}

int32_t stellar_ffmpeg_capture_frame_with_io(
    StellarFFmpegCaptureContext *context,
    void *opaque,
    StellarFFmpegReadCallback read_callback,
    StellarFFmpegSeekCallback seek_callback,
    const char *filename_hint,
    int64_t timestamp_milliseconds,
    int32_t maximum_pixel_dimension,
    StellarFFmpegDecodedFrame *output) {
  if (context == NULL || opaque == NULL || read_callback == NULL || seek_callback == NULL ||
      filename_hint == NULL || filename_hint[0] == '\0' || output == NULL ||
      timestamp_milliseconds < 0 || maximum_pixel_dimension < 0) {
    return STELLAR_FFMPEG_CAPTURE_INVALID_ARGUMENT;
  }
  memset(output, 0, sizeof(*output));
  if (stellar_ffmpeg_is_cancelled(context)) {
    return STELLAR_FFMPEG_CAPTURE_CANCELLED;
  }

  AVFormatContext *format_context = avformat_alloc_context();
  uint8_t *io_buffer = av_malloc(32 * 1024);
  if (format_context == NULL || io_buffer == NULL) {
    avformat_free_context(format_context);
    av_free(io_buffer);
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }
  AVIOContext *io_context = avio_alloc_context(
      io_buffer,
      32 * 1024,
      0,
      opaque,
      read_callback,
      NULL,
      seek_callback);
  if (io_context == NULL) {
    avformat_free_context(format_context);
    av_free(io_buffer);
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }
  format_context->pb = io_context;
  format_context->flags |= AVFMT_FLAG_CUSTOM_IO;
  format_context->interrupt_callback.callback = stellar_ffmpeg_interrupt;
  format_context->interrupt_callback.opaque = context;

  int32_t capture_result = avformat_open_input(
      &format_context,
      filename_hint,
      NULL,
      NULL);
  if (capture_result >= 0) {
    capture_result = stellar_ffmpeg_capture_opened_input(
        context,
        format_context,
        timestamp_milliseconds,
        maximum_pixel_dimension,
        output);
  }
  avformat_close_input(&format_context);
  avio_context_free(&io_context);
  if (capture_result != STELLAR_FFMPEG_CAPTURE_OK) {
    stellar_ffmpeg_decoded_frame_destroy(output);
  }
  return capture_result;
}

static char *stellar_ffmpeg_duplicate(const char *value) {
  return value == NULL || value[0] == '\0' ? NULL : av_strdup(value);
}

static int32_t stellar_ffmpeg_stream_kind(enum AVMediaType type) {
  switch (type) {
    case AVMEDIA_TYPE_VIDEO:
      return STELLAR_FFMPEG_STREAM_VIDEO;
    case AVMEDIA_TYPE_AUDIO:
      return STELLAR_FFMPEG_STREAM_AUDIO;
    case AVMEDIA_TYPE_SUBTITLE:
      return STELLAR_FFMPEG_STREAM_SUBTITLE;
    case AVMEDIA_TYPE_ATTACHMENT:
      return STELLAR_FFMPEG_STREAM_ATTACHMENT;
    default:
      return 0;
  }
}

static double stellar_ffmpeg_frame_rate(AVStream *stream) {
  AVRational rate = stream->avg_frame_rate;
  if (rate.num <= 0 || rate.den <= 0) {
    rate = stream->r_frame_rate;
  }
  return rate.num > 0 && rate.den > 0 ? av_q2d(rate) : 0;
}

static int32_t stellar_ffmpeg_probe_opened_input(
    StellarFFmpegCaptureContext *context,
    AVFormatContext *format_context,
    StellarFFmpegTechnicalProbe *output) {
  int result = avformat_find_stream_info(format_context, NULL);
  if (result < 0) {
    return stellar_ffmpeg_is_cancelled(context)
        ? STELLAR_FFMPEG_CAPTURE_CANCELLED
        : result;
  }
  if (format_context->nb_streams > INT32_MAX) {
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }

  output->container = stellar_ffmpeg_duplicate(
      format_context->iformat == NULL ? NULL : format_context->iformat->name);
  output->duration_milliseconds = format_context->duration == AV_NOPTS_VALUE
      ? 0
      : av_rescale_q(format_context->duration, AV_TIME_BASE_Q, (AVRational){1, 1000});
  output->overall_bit_rate = format_context->bit_rate > 0 ? format_context->bit_rate : 0;
  output->stream_count = (int32_t)format_context->nb_streams;
  if (output->stream_count > 0) {
    output->streams = av_calloc(
        (size_t)output->stream_count,
        sizeof(*output->streams));
    if (output->streams == NULL) {
      return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
    }
  }

  bool selected_video = false;
  bool selected_audio = false;
  for (int32_t index = 0; index < output->stream_count; index++) {
    if (stellar_ffmpeg_is_cancelled(context)) {
      return STELLAR_FFMPEG_CAPTURE_CANCELLED;
    }
    AVStream *source = format_context->streams[index];
    AVCodecParameters *parameters = source->codecpar;
    StellarFFmpegTechnicalStream *stream = &output->streams[index];
    stream->stream_index = (int32_t)source->index;
    stream->kind = stellar_ffmpeg_stream_kind(parameters->codec_type);
    stream->codec = stellar_ffmpeg_duplicate(avcodec_get_name(parameters->codec_id));
    AVDictionaryEntry *language = av_dict_get(source->metadata, "language", NULL, 0);
    AVDictionaryEntry *title = av_dict_get(source->metadata, "title", NULL, 0);
    stream->language = stellar_ffmpeg_duplicate(language == NULL ? NULL : language->value);
    stream->title = stellar_ffmpeg_duplicate(title == NULL ? NULL : title->value);
    stream->bit_rate = parameters->bit_rate > 0 ? parameters->bit_rate : 0;
    stream->width = parameters->width;
    stream->height = parameters->height;
    stream->frame_rate = parameters->codec_type == AVMEDIA_TYPE_VIDEO
        ? stellar_ffmpeg_frame_rate(source)
        : 0;
    stream->hdr_profile = stellar_ffmpeg_duplicate(av_color_transfer_name(parameters->color_trc));
    stream->channel_count = parameters->ch_layout.nb_channels;
    if (parameters->ch_layout.nb_channels > 0) {
      char channel_layout[128] = {0};
      if (av_channel_layout_describe(
              &parameters->ch_layout,
              channel_layout,
              sizeof(channel_layout)) >= 0) {
        stream->channel_layout = stellar_ffmpeg_duplicate(channel_layout);
      }
    }
    stream->sample_rate = parameters->sample_rate;
    stream->is_default = (source->disposition & AV_DISPOSITION_DEFAULT) != 0;
    stream->is_forced = (source->disposition & AV_DISPOSITION_FORCED) != 0;
    if ((source->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0) {
      output->has_embedded_cover = true;
    }

    if (!selected_video && parameters->codec_type == AVMEDIA_TYPE_VIDEO &&
        (source->disposition & AV_DISPOSITION_ATTACHED_PIC) == 0) {
      output->video_codec = stellar_ffmpeg_duplicate(avcodec_get_name(parameters->codec_id));
      output->width = parameters->width;
      output->height = parameters->height;
      output->frame_rate = stream->frame_rate;
      output->hdr_profile = stellar_ffmpeg_duplicate(av_color_transfer_name(parameters->color_trc));
      selected_video = true;
    }
    if (!selected_audio && parameters->codec_type == AVMEDIA_TYPE_AUDIO) {
      output->audio_codec = stellar_ffmpeg_duplicate(avcodec_get_name(parameters->codec_id));
      output->audio_channels = parameters->ch_layout.nb_channels;
      selected_audio = true;
    }
  }
  return STELLAR_FFMPEG_CAPTURE_OK;
}

int32_t stellar_ffmpeg_probe_with_io(
    StellarFFmpegCaptureContext *context,
    void *opaque,
    StellarFFmpegReadCallback read_callback,
    StellarFFmpegSeekCallback seek_callback,
    const char *filename_hint,
    StellarFFmpegTechnicalProbe *output) {
  if (context == NULL || opaque == NULL || read_callback == NULL || seek_callback == NULL ||
      filename_hint == NULL || filename_hint[0] == '\0' || output == NULL) {
    return STELLAR_FFMPEG_CAPTURE_INVALID_ARGUMENT;
  }
  memset(output, 0, sizeof(*output));
  if (stellar_ffmpeg_is_cancelled(context)) {
    return STELLAR_FFMPEG_CAPTURE_CANCELLED;
  }

  AVFormatContext *format_context = avformat_alloc_context();
  uint8_t *io_buffer = av_malloc(32 * 1024);
  if (format_context == NULL || io_buffer == NULL) {
    avformat_free_context(format_context);
    av_free(io_buffer);
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }
  AVIOContext *io_context = avio_alloc_context(
      io_buffer,
      32 * 1024,
      0,
      opaque,
      read_callback,
      NULL,
      seek_callback);
  if (io_context == NULL) {
    avformat_free_context(format_context);
    av_free(io_buffer);
    return STELLAR_FFMPEG_CAPTURE_ALLOCATION_FAILED;
  }
  format_context->pb = io_context;
  format_context->flags |= AVFMT_FLAG_CUSTOM_IO;
  format_context->interrupt_callback.callback = stellar_ffmpeg_interrupt;
  format_context->interrupt_callback.opaque = context;

  int32_t probe_result = avformat_open_input(&format_context, filename_hint, NULL, NULL);
  if (probe_result >= 0) {
    probe_result = stellar_ffmpeg_probe_opened_input(context, format_context, output);
  }
  avformat_close_input(&format_context);
  avio_context_free(&io_context);
  if (probe_result != STELLAR_FFMPEG_CAPTURE_OK) {
    stellar_ffmpeg_technical_probe_destroy(output);
  }
  return probe_result;
}
