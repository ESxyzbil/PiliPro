#include "mp4_transcoder.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <winrt/base.h>

#include <cstdio>
#include <string>
#include <vector>

namespace mp4_transcoder {
namespace {

using winrt::com_ptr;

constexpr UINT32 kAacBitrate = 192000;   // 192 kbps
constexpr UINT32 kAacSampleRate = 48000;  // AAC-LC 常用采样率
constexpr UINT16 kAacChannels = 2;

// 部分 SDK 里这几个常量是带符号枚举，隐式转 DWORD 会触发 C4245（本工程把警告当错误）
constexpr DWORD kFirstVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kFirstAudioStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
constexpr DWORD kMediaSource =
    static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE);

std::string HrMessage(const char* what, HRESULT hr) {
  char buf[160];
  std::snprintf(buf, sizeof(buf), "%s 失败 (0x%08lX)", what,
                static_cast<unsigned long>(hr));
  return buf;
}

std::string CodecName(const GUID& sub) {
  if (sub == MFVideoFormat_H264) return "avc1";
  if (sub == MFVideoFormat_HEVC) return "hev1";
  if (sub == MFVideoFormat_HEVC_ES) return "hev1";
  if (sub == MFVideoFormat_AV1) return "av01";
  if (sub == MFAudioFormat_AAC) return "mp4a";
  if (sub == MFAudioFormat_FLAC) return "fLaC";
  if (sub == MFAudioFormat_MP3) return "mp3";
  if (sub == MFAudioFormat_Dolby_AC3) return "ac-3";
  if (sub == MFAudioFormat_Dolby_DDPlus) return "ec-3";
  if (sub == MFAudioFormat_PCM) return "pcm";
  return "unknown";
}

/// Media Foundation 生命周期管理（引用计数式，可重入）。
class MfScope {
 public:
  MfScope() : hr_(MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET)) {}
  ~MfScope() {
    if (SUCCEEDED(hr_)) {
      MFShutdown();
    }
  }
  HRESULT hr() const { return hr_; }

 private:
  HRESULT hr_;
};

struct OneStream {
  DWORD reader_stream = 0;
  DWORD writer_stream = 0;
  bool active = false;
  bool eos = false;
  bool has_sample = false;
  com_ptr<IMFSample> sample;
  LONGLONG time = 0;
};

/// 从 reader 取下一个样本；返回 false 表示出错。
bool PullSample(IMFSourceReader* reader, OneStream* s) {
  if (!s->active || s->has_sample || s->eos) {
    return true;
  }
  DWORD flags = 0;
  LONGLONG ts = 0;
  com_ptr<IMFSample> sample;
  HRESULT hr = reader->ReadSample(s->reader_stream, 0, nullptr, &flags, &ts,
                                  sample.put());
  if (FAILED(hr)) {
    return false;
  }
  if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
    s->eos = true;
    return true;
  }
  if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
    // 分辨率/格式中途变化：跳过该样本即可（转封装场景极少发生）
    return true;
  }
  if (sample == nullptr) {
    return true;
  }
  s->sample = sample;
  s->has_sample = true;
  s->time = ts;
  return true;
}

/// 配置一条轨道：能直通则直通，否则请求解码后重编码。
HRESULT AddPassthroughStream(IMFSinkWriter* writer, IMFMediaType* native_type,
                             DWORD* out_index) {
  HRESULT hr = writer->AddStream(native_type, out_index);
  if (FAILED(hr)) {
    return hr;
  }
  return writer->SetInputMediaType(*out_index, native_type, nullptr);
}

HRESULT ConfigureVideo(IMFSourceReader* reader, IMFSinkWriter* writer,
                       OneStream* vs, Result* result) {
  com_ptr<IMFMediaType> native_type;
  if (FAILED(reader->GetNativeMediaType(kFirstVideoStream, 0,
                                        native_type.put()))) {
    return S_OK;  // 无视频轨
  }
  GUID sub = GUID_NULL;
  native_type->GetGUID(MF_MT_SUBTYPE, &sub);
  result->video_codec = CodecName(sub);

  vs->active = true;
  vs->reader_stream = kFirstVideoStream;

  if (sub == MFVideoFormat_H264) {
    HRESULT hr = AddPassthroughStream(writer, native_type.get(),
                                      &vs->writer_stream);
    if (FAILED(hr)) {
      return hr;
    }
    result->video_action = "copy";
    return S_OK;
  }

  // 需要重编码：输出 H.264
  UINT32 width = 0, height = 0;
  MFGetAttributeSize(native_type.get(), MF_MT_FRAME_SIZE, &width, &height);
  UINT32 fps_num = 30, fps_den = 1;
  MFGetAttributeRatio(native_type.get(), MF_MT_FRAME_RATE, &fps_num, &fps_den);
  if (fps_num == 0 || fps_den == 0) {
    fps_num = 30;
    fps_den = 1;
  }
  if (width == 0 || height == 0) {
    return MF_E_INVALIDMEDIATYPE;
  }
  // 粗略码率：约 0.08 bit/像素/帧
  UINT32 bitrate = static_cast<UINT32>(
      static_cast<double>(width) * height * fps_num / fps_den * 0.08);
  if (bitrate < 500000) bitrate = 500000;
  if (bitrate > 20000000) bitrate = 20000000;

  com_ptr<IMFMediaType> out_type;
  HRESULT hr = MFCreateMediaType(out_type.put());
  if (FAILED(hr)) return hr;
  out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  out_type->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
  out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  MFSetAttributeSize(out_type.get(), MF_MT_FRAME_SIZE, width, height);
  MFSetAttributeRatio(out_type.get(), MF_MT_FRAME_RATE, fps_num, fps_den);
  MFSetAttributeRatio(out_type.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  hr = writer->AddStream(out_type.get(), &vs->writer_stream);
  if (FAILED(hr)) {
    return hr;
  }

  // 让 reader 解码为 NV12 交给编码器
  com_ptr<IMFMediaType> want;
  hr = MFCreateMediaType(want.put());
  if (FAILED(hr)) return hr;
  want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  want->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  MFSetAttributeSize(want.get(), MF_MT_FRAME_SIZE, width, height);
  MFSetAttributeRatio(want.get(), MF_MT_FRAME_RATE, fps_num, fps_den);
  hr = reader->SetCurrentMediaType(vs->reader_stream, nullptr, want.get());
  if (FAILED(hr)) {
    // 退回让解码器自选格式
    hr = reader->SetCurrentMediaType(vs->reader_stream, nullptr, nullptr);
    if (FAILED(hr)) {
      return hr;
    }
  }
  com_ptr<IMFMediaType> decoded;
  hr = reader->GetCurrentMediaType(vs->reader_stream, decoded.put());
  if (FAILED(hr)) {
    return hr;
  }
  hr = writer->SetInputMediaType(vs->writer_stream, decoded.get(), nullptr);
  if (FAILED(hr)) {
    return hr;
  }
  result->video_action = "encode";
  return S_OK;
}

HRESULT ConfigureAudio(IMFSourceReader* reader, IMFSinkWriter* writer,
                       OneStream* as, Result* result) {
  com_ptr<IMFMediaType> native_type;
  if (FAILED(reader->GetNativeMediaType(kFirstAudioStream, 0,
                                        native_type.put()))) {
    return S_OK;  // 无音频轨
  }
  GUID sub = GUID_NULL;
  native_type->GetGUID(MF_MT_SUBTYPE, &sub);
  result->audio_codec = CodecName(sub);

  as->active = true;
  as->reader_stream = kFirstAudioStream;

  if (sub == MFAudioFormat_AAC) {
    HRESULT hr = AddPassthroughStream(writer, native_type.get(),
                                      &as->writer_stream);
    if (FAILED(hr)) {
      return hr;
    }
    result->audio_action = "copy";
    return S_OK;
  }

  // 解码为 48kHz/16bit/立体声 PCM，再编码为 AAC
  com_ptr<IMFMediaType> want;
  HRESULT hr = MFCreateMediaType(want.put());
  if (FAILED(hr)) return hr;
  want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  want->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kAacChannels);
  want->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAacSampleRate);
  want->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  want->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, kAacChannels * 2);
  want->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                  kAacSampleRate * kAacChannels * 2);
  want->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
  hr = reader->SetCurrentMediaType(as->reader_stream, nullptr, want.get());
  if (FAILED(hr)) {
    return hr;
  }

  com_ptr<IMFMediaType> aac_type;
  hr = MFCreateMediaType(aac_type.put());
  if (FAILED(hr)) return hr;
  aac_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  aac_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  aac_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  aac_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAacSampleRate);
  aac_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kAacChannels);
  aac_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAacBitrate / 8);
  aac_type->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
  aac_type->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
  hr = writer->AddStream(aac_type.get(), &as->writer_stream);
  if (FAILED(hr)) {
    return hr;
  }

  com_ptr<IMFMediaType> actual;
  hr = reader->GetCurrentMediaType(as->reader_stream, actual.put());
  if (FAILED(hr)) {
    return hr;
  }
  hr = writer->SetInputMediaType(as->writer_stream, actual.get(), nullptr);
  if (FAILED(hr)) {
    return hr;
  }
  result->audio_action = "encode";
  return S_OK;
}

}  // namespace

Result TranscodeToH264Aac(const std::wstring& input_path,
                          const std::wstring& output_path,
                          const ProgressCallback& on_progress) {
  Result result;
  MfScope mf;
  if (FAILED(mf.hr())) {
    result.error = HrMessage("MFStartup", mf.hr());
    return result;
  }

  com_ptr<IMFAttributes> reader_attrs;
  HRESULT hr = MFCreateAttributes(reader_attrs.put(), 3);
  if (FAILED(hr)) {
    result.error = HrMessage("MFCreateAttributes", hr);
    return result;
  }
  reader_attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);

  com_ptr<IMFByteStream> input_stream;
  hr = MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                    MF_FILEFLAGS_NONE, input_path.c_str(),
                    input_stream.put());
  if (FAILED(hr)) {
    result.error = HrMessage("打开输入文件", hr);
    return result;
  }

  com_ptr<IMFSourceReader> reader;
  // 注意：不要用 MFCreateSourceReaderFromURL —— 在受限环境下 URL scheme handler
  // 会因权限问题失败（0x80070005），直接用字节流更稳。
  hr = MFCreateSourceReaderFromByteStream(input_stream.get(), reader_attrs.get(),
                                          reader.put());
  if (FAILED(hr)) {
    result.error = HrMessage("创建源读取器", hr);
    return result;
  }

  com_ptr<IMFAttributes> writer_attrs;
  hr = MFCreateAttributes(writer_attrs.put(), 2);
  if (FAILED(hr)) {
    result.error = HrMessage("MFCreateAttributes", hr);
    return result;
  }
  writer_attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  writer_attrs->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);

  com_ptr<IMFByteStream> output_stream;
  hr = MFCreateFile(MF_ACCESSMODE_WRITE, MF_OPENMODE_DELETE_IF_EXIST,
                    MF_FILEFLAGS_NONE, output_path.c_str(),
                    output_stream.put());
  if (FAILED(hr)) {
    result.error = HrMessage("创建输出文件", hr);
    return result;
  }

  com_ptr<IMFSinkWriter> writer;
  hr = MFCreateSinkWriterFromURL(output_path.c_str(), output_stream.get(),
                                 writer_attrs.get(), writer.put());
  if (FAILED(hr)) {
    result.error = HrMessage("创建写入器", hr);
    return result;
  }

  OneStream vs;
  OneStream as;
  hr = ConfigureVideo(reader.get(), writer.get(), &vs, &result);
  if (FAILED(hr)) {
    result.error = HrMessage("配置视频轨", hr);
    return result;
  }
  hr = ConfigureAudio(reader.get(), writer.get(), &as, &result);
  if (FAILED(hr)) {
    result.error = HrMessage("配置音频轨", hr);
    return result;
  }
  if (!vs.active && !as.active) {
    result.error = "输入文件中没有可用的音视频轨";
    return result;
  }

  hr = writer->BeginWriting();
  if (FAILED(hr)) {
    result.error = HrMessage("BeginWriting", hr);
    return result;
  }

  // 输入总时长（100ns）
  LONGLONG duration = 0;
  {
    PROPVARIANT var;
    PropVariantInit(&var);
    if (SUCCEEDED(reader->GetPresentationAttribute(
            kMediaSource, MF_PD_DURATION, &var)) &&
        var.vt == VT_UI8) {
      duration = static_cast<LONGLONG>(var.uhVal.QuadPart);
    }
    PropVariantClear(&var);
  }

  LONGLONG last_time = 0;
  while (vs.active || as.active) {
    if (!PullSample(reader.get(), &vs) || !PullSample(reader.get(), &as)) {
      result.error = "读取样本失败";
      return result;
    }
    OneStream* pick = nullptr;
    if (vs.active && vs.has_sample && (!as.active || !as.has_sample ||
                                       vs.time <= as.time)) {
      pick = &vs;
    } else if (as.active && as.has_sample) {
      pick = &as;
    }
    if (pick == nullptr) {
      if ((!vs.active || vs.eos || !vs.has_sample) &&
          (!as.active || as.eos || !as.has_sample)) {
        break;  // 两路都结束
      }
      continue;
    }
    hr = writer->WriteSample(pick->writer_stream, pick->sample.get());
    if (FAILED(hr)) {
      result.error = HrMessage("写入样本", hr);
      return result;
    }
    if (pick->time > last_time) {
      last_time = pick->time;
    }
    pick->has_sample = false;
    pick->sample = nullptr;
    if ((!vs.active || vs.eos) && (!as.active || as.eos)) {
      break;
    }
    if (on_progress && duration > 0) {
      double p = static_cast<double>(last_time) / static_cast<double>(duration);
      if (p < 0) p = 0;
      if (p > 1) p = 1;
      on_progress(p);
    }
  }

  hr = writer->Finalize();
  if (FAILED(hr)) {
    result.error = HrMessage("Finalize", hr);
    return result;
  }
  if (on_progress) {
    on_progress(1.0);
  }
  result.ok = true;
  return result;
}

}  // namespace mp4_transcoder
