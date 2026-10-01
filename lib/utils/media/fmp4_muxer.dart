// fMP4（B 站 DASH m4s 分片）→ 标准渐进式 MP4 重封装。
//
// 纯 Dart 实现，不依赖 FFmpeg：解析各 m4s 的初始化段（ftyp/moov）与全部分片
// （moof/mdat），按解码时间交错样本，重建 stbl 样本表（stts/ctts/stss/stsc/stsz/stco）
// 后写出带完整 moov 的普通 MP4。样本数据原样搬运，不重新编码。
import 'dart:io';
import 'dart:typed_data';

/// 输出轨道信息。
class Mp4TrackInfo {
  const Mp4TrackInfo({
    required this.codec,
    required this.timescale,
    required this.durationUs,
    required this.sampleCount,
    required this.width,
    required this.height,
  });

  /// 采样描述四字符码（avc1/hev1/av01/mp4a/fLaC…）。
  final String codec;
  final int timescale;
  final int durationUs;
  final int sampleCount;
  final int width;
  final int height;

  bool get isH264 => codec == 'avc1' || codec == 'avc3';
  bool get isAac => codec == 'mp4a';
}

/// 合并结果。
class Mp4MergeResult {
  const Mp4MergeResult({
    required this.path,
    required this.size,
    required this.video,
    required this.audio,
  });

  final String path;
  final int size;
  final Mp4TrackInfo video;
  final Mp4TrackInfo? audio;

  /// 视频已是 H.264。
  bool get videoIsH264 => video.isH264;

  /// 无音频轨或音频已是 AAC。
  bool get audioIsAac => audio == null || audio!.isAac;

  /// 结果本身即是 H.264+AAC 的 MP4，无需转码。
  bool get isCompatible => videoIsH264 && audioIsAac;

  @override
  String toString() =>
      'Mp4MergeResult($path, ${size ~/ 1024}KB, video=${video.codec} '
      '${video.width}x${video.height} ${video.durationUs ~/ 1000}ms, '
      'audio=${audio?.codec} ${(audio?.durationUs ?? 0) ~/ 1000}ms)';
}

/// 合并过程中的异常。
class Mp4MuxException implements Exception {
  Mp4MuxException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把 B 站 DASH 的视频/音频 m4s 合并为一个 MP4 文件。
abstract final class Fmp4Muxer {
  /// 单个数据块的目标时长（微秒），用于控制音视频交错粒度。
  static const int chunkDurationUs = 500 * 1000;

  /// 合并 [videoPath] 与 [audioPath]（可空）到 [outputPath]。
  ///
  /// [onProgress] 回调进度 0~1（按已写出字节数估算）。
  static Future<Mp4MergeResult> merge({
    required String videoPath,
    String? audioPath,
    required String outputPath,
    void Function(double progress)? onProgress,
  }) async {
    var videoSource = await _SourceFile.open(videoPath);
    _SourceFile? audioSource;
    try {
      if (audioPath != null && audioPath.isNotEmpty) {
        audioSource = await _SourceFile.open(audioPath);
        if (videoSource.videoTrack == null &&
            audioSource.videoTrack != null) {
          // 两个文件角色颠倒时自动纠正
          final tmp = videoSource;
          videoSource = audioSource;
          audioSource = tmp;
        }
      }
      final videoTrack = videoSource.videoTrack;
      if (videoTrack == null) {
        throw Mp4MuxException('视频文件中未找到视频轨');
      }
      if (videoTrack.samples.isEmpty) {
        // 例如离线缓存里的整段 0.mp4（渐进式 MP4，没有 moof/mdat 分片）
        throw Mp4MuxException('视频文件不是 DASH 分片（fMP4），无需合并');
      }
      final audioTrack = audioSource?.audioTrack;
      if (audioSource != null && audioTrack == null) {
        throw Mp4MuxException('音频文件中未找到音频轨');
      }
      if (audioTrack != null && audioTrack.samples.isEmpty) {
        throw Mp4MuxException('音频文件不是 DASH 分片（fMP4），无需合并');
      }

      final outFile = File(outputPath);
      await outFile.parent.create(recursive: true);
      if (outFile.existsSync()) {
        await outFile.delete();
      }

      final vOut = _OutTrack(videoTrack, videoSource.file);
      final aOut = audioTrack == null
          ? null
          : _OutTrack(audioTrack, audioSource!.file);
      final totalBytes = vOut.totalSourceBytes + (aOut?.totalSourceBytes ?? 0);

      await _writeMp4(
        outputPath: outputPath,
        ftypBytes: videoSource.ftypBytes,
        vOut: vOut,
        aOut: aOut,
        totalBytes: totalBytes,
        onProgress: onProgress,
      );

      final size = await outFile.length();
      return Mp4MergeResult(
        path: outputPath,
        size: size,
        video: Mp4TrackInfo(
          codec: videoTrack.codec,
          timescale: videoTrack.timescale,
          durationUs: videoTrack.durationUs,
          sampleCount: videoTrack.samples.length,
          width: videoTrack.width,
          height: videoTrack.height,
        ),
        audio: audioTrack == null
            ? null
            : Mp4TrackInfo(
                codec: audioTrack.codec,
                timescale: audioTrack.timescale,
                durationUs: audioTrack.durationUs,
                sampleCount: audioTrack.samples.length,
                width: 0,
                height: 0,
              ),
      );
    } finally {
      await videoSource.close();
      await audioSource?.close();
    }
  }

  static Future<void> _writeMp4({
    required String outputPath,
    required Uint8List ftypBytes,
    required _OutTrack vOut,
    required _OutTrack? aOut,
    required int totalBytes,
    void Function(double progress)? onProgress,
  }) async {
    final out = await File(outputPath).open(mode: FileMode.writeOnly);
    try {
      await out.writeFrom(ftypBytes);

      final mdatHeaderPos = await out.position();
      await out.writeFrom(_u32(0));
      await out.writeFrom(_ascii('mdat'));
      final mdatDataStart = await out.position();

      var copied = 0;
      var lastReported = 0.0;
      while (vOut.hasRemaining || (aOut?.hasRemaining ?? false)) {
        final track = _pickTrack(vOut, aOut);
        copied += await track.emitChunk(out, mdatDataStart);
        if (onProgress != null && totalBytes > 0) {
          final p = (copied / totalBytes).clamp(0.0, 1.0);
          if (p - lastReported >= 0.02 || p >= 1) {
            lastReported = p;
            onProgress(p);
          }
        }
      }

      final mdatEnd = await out.position();
      final mdatSize = mdatEnd - mdatHeaderPos;
      if (mdatSize > 0xffffffff) {
        throw Mp4MuxException('输出文件超过 4GB，暂不支持');
      }

      final moov = _buildMoov(video: vOut, audio: aOut);
      await out.writeFrom(moov);

      // 回填 mdat 大小
      await out.setPosition(mdatHeaderPos);
      await out.writeFrom(_u32(mdatSize));
      await out.flush();
    } finally {
      await out.close();
    }
    onProgress?.call(1);
  }

  /// 选择下一块所属轨道：解码时间更早者优先，相同则视频优先。
  static _OutTrack _pickTrack(_OutTrack v, _OutTrack? a) {
    if (a == null || !a.hasRemaining) {
      return v;
    }
    if (!v.hasRemaining) {
      return a;
    }
    return v.nextDtsUs <= a.nextDtsUs ? v : a;
  }

  static Uint8List _buildMoov({
    required _OutTrack video,
    required _OutTrack? audio,
  }) {
    const movieTimescale = 1000;
    final videoDurUs = video.durationUs;
    final audioDurUs = audio?.durationUs ?? 0;
    final movieDurUs = videoDurUs > audioDurUs ? videoDurUs : audioDurUs;
    final movieDuration = movieDurUs * movieTimescale ~/ 1000000;
    final trackCount = audio == null ? 1 : 2;

    return _box('moov', (w) {
      w.box('mvhd', (w) {
        w.u32(0); // version 0 + flags
        w.u32(0); // creation_time
        w.u32(0); // modification_time
        w.u32(movieTimescale);
        w.u32(movieDuration);
        w.u32(0x00010000); // rate 1.0
        w.u16(0x0100); // volume 1.0
        w.u16(0); // reserved
        w.u32(0);
        w.u32(0);
        w.matrix();
        w.bytes(List<int>.filled(24, 0)); // pre_defined
        w.u32(trackCount + 1); // next_track_ID
      });
      w.bytes(_buildTrak(video, 1, movieTimescale));
      if (audio != null) {
        w.bytes(_buildTrak(audio, 2, movieTimescale));
      }
    });
  }

  static Uint8List _buildTrak(
    _OutTrack track,
    int trackId,
    int movieTimescale,
  ) {
    final src = track.src;
    final isVideo = src.isVideo;
    final durationInMovieScale =
        track.durationUs * movieTimescale ~/ 1000000;

    return _box('trak', (w) {
      w.box('tkhd', (w) {
        w.u32(0x00000007); // flags: enabled | in_movie | in_preview
        w.u32(0);
        w.u32(0);
        w.u32(trackId);
        w.u32(0); // reserved
        w.u32(durationInMovieScale);
        w.u32(0); // reserved
        w.u32(0);
        w.u16(0); // layer
        w.u16(0); // alternate_group
        w.u16(isVideo ? 0 : 0x0100); // volume
        w.u16(0); // reserved
        w.bytes(src.matrix.isEmpty ? _identityMatrix : src.matrix);
        w.u32(isVideo ? src.width : 0);
        w.u32(isVideo ? src.height : 0);
      });
      w.box('mdia', (w) {
        w.box('mdhd', (w) {
          w.u32(0);
          w.u32(0);
          w.u32(0);
          w.u32(src.timescale);
          w.u32(track.mediaDuration);
          w.u16(src.language);
          w.u16(0);
        });
        w.bytes(src.hdlrBytes!);
        w.box('minf', (w) {
          if (isVideo) {
            w.box('vmhd', (w) {
              w.u32(0x00000001);
              w.u16(0);
              w.u16(0);
              w.u16(0);
              w.u16(0);
            });
          } else {
            w.box('smhd', (w) {
              w.u32(0);
              w.u16(0);
              w.u16(0);
            });
          }
          w.bytes(src.dinfBytes!);
          w.bytes(track.buildStbl());
        });
      });
    });
  }

  static Uint8List _u32(int v) {
    final b = ByteData(4)..setUint32(0, v & 0xffffffff);
    return b.buffer.asUint8List();
  }

  static Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);
}

const List<int> _identityMatrix = <int>[
  0x00, 0x01, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00,
  0x00, 0x01, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00,
  0x40, 0x00, 0x00, 0x00,
];

/// 写出一个 box：4 字节大小 + 类型 + 由 [body] 填充的内容。
Uint8List _box(String type, void Function(_BoxWriter w) body) {
  final payload = _BoxWriter();
  body(payload);
  final data = payload.take();
  final header = _BoxWriter()
    ..u32(data.length + 8)
    ..ascii(type);
  return Uint8List.fromList([...header.take(), ...data]);
}

class _BoxWriter {
  final BytesBuilder _b = BytesBuilder(copy: true);

  int get length => _b.length;

  void u8(int v) => _b.addByte(v & 0xff);

  void u16(int v) {
    _b.addByte((v >> 8) & 0xff);
    _b.addByte(v & 0xff);
  }

  void u32(int v) {
    _b.addByte((v >> 24) & 0xff);
    _b.addByte((v >> 16) & 0xff);
    _b.addByte((v >> 8) & 0xff);
    _b.addByte(v & 0xff);
  }

  void i32(int v) => u32(v);

  void ascii(String s) => _b.add(s.codeUnits);

  void bytes(List<int> v) => _b.add(v);

  void matrix() => bytes(_identityMatrix);

  void box(String type, void Function(_BoxWriter w) body) {
    final payload = _BoxWriter();
    body(payload);
    final data = payload.take();
    u32(data.length + 8);
    ascii(type);
    bytes(data);
  }

  Uint8List take() => _b.takeBytes();
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

class _BoxHeader {
  const _BoxHeader(this.type, this.start, this.size, this.headerSize);

  final String type;
  final int start;
  final int size;
  final int headerSize;

  int get end => start + size;
  int get payloadStart => start + headerSize;
}

/// 一个 m4s 文件解析后的信息。
class _SourceFile {
  _SourceFile(this.path, this.file, this.ftypBytes, this.tracks);

  final String path;
  final RandomAccessFile file;
  final Uint8List ftypBytes;
  final List<_TrackData> tracks;

  _TrackData? get videoTrack {
    for (final t in tracks) {
      if (t.isVideo) {
        return t;
      }
    }
    return null;
  }

  _TrackData? get audioTrack {
    for (final t in tracks) {
      if (t.handler == 'soun') {
        return t;
      }
    }
    return null;
  }

  static Future<_SourceFile> open(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw Mp4MuxException('文件不存在：$path');
    }
    final raf = await file.open();
    try {
      final size = await raf.length();
      Uint8List? ftyp;
      final moovBoxes = <_BoxHeader>[];
      var off = 0;
      while (off + 8 <= size) {
        final h = await _readBoxHeader(raf, off, size);
        if (h == null || h.size < h.headerSize) {
          break;
        }
        if (h.type == 'ftyp' && ftyp == null) {
          ftyp = await _readBytes(raf, h.start, h.size);
        } else if (h.type == 'moov') {
          moovBoxes.add(h);
        }
        off = h.end;
      }
      if (ftyp == null) {
        throw Mp4MuxException('不是合法的 MP4 文件（缺少 ftyp）：$path');
      }
      final tracks = <_TrackData>[];
      for (final h in moovBoxes) {
        final bytes = await _readBytes(raf, h.start, h.size);
        // 只把 moov 的内容交给解析器（内部偏移相对内容起点）
        tracks.addAll(
          _parseMoov(
            Uint8List.sublistView(bytes, h.headerSize, h.size),
          ),
        );
      }
      if (tracks.isEmpty) {
        throw Mp4MuxException('文件中未找到轨道：$path');
      }
      final source = _SourceFile(path, raf, ftyp, tracks);
      await source._parseFragments(size);
      return source;
    } catch (e) {
      await raf.close();
      rethrow;
    }
  }

  Future<void> _parseFragments(int size) async {
    final byId = <int, _TrackData>{};
    for (final t in tracks) {
      byId[t.trackId] = t;
    }
    var off = 0;
    while (off + 8 <= size) {
      final h = await _readBoxHeader(file, off, size);
      if (h == null || h.size < h.headerSize) {
        break;
      }
      if (h.type == 'moof') {
        final bytes = await _readBytes(file, h.start, h.size);
        _parseMoof(bytes, h.start, h.headerSize, byId);
      }
      off = h.end;
    }
    for (final t in tracks) {
      t.finish();
    }
  }

  Future<void> close() => file.close();

  static Future<_BoxHeader?> _readBoxHeader(
    RandomAccessFile f,
    int offset,
    int limit,
  ) async {
    if (offset + 8 > limit) {
      return null;
    }
    await f.setPosition(offset);
    final head = await f.read(16);
    if (head.length < 8) {
      return null;
    }
    final bd = ByteData.sublistView(head);
    var size = bd.getUint32(0);
    final type = String.fromCharCodes(head.sublist(4, 8));
    var headerSize = 8;
    if (size == 1) {
      if (head.length < 16) {
        return null;
      }
      size = bd.getUint64(8);
      headerSize = 16;
    } else if (size == 0) {
      size = limit - offset;
    }
    return _BoxHeader(type, offset, size, headerSize);
  }

  static Future<Uint8List> _readBytes(
    RandomAccessFile f,
    int offset,
    int length,
  ) async {
    await f.setPosition(offset);
    final data = await f.read(length);
    if (data.length != length) {
      throw Mp4MuxException('读取文件失败（偏移 $offset，期望 $length 字节）');
    }
    return data;
  }

  static List<_TrackData> _parseMoov(Uint8List d) {
    final result = <_TrackData>[];
    final trex = <int, _Trex>{};
    for (final b in _children(d, 0, d.length)) {
      if (b.type == 'mvex') {
        for (final c in _children(d, b.payloadStart, b.end)) {
          if (c.type == 'trex') {
            final bd = ByteData.sublistView(d, c.payloadStart, c.end);
            trex[bd.getUint32(4)] = _Trex(
              defaultSampleDuration: bd.getUint32(12),
              defaultSampleSize: bd.getUint32(16),
              defaultSampleFlags: bd.getUint32(20),
            );
          }
        }
      } else if (b.type == 'trak') {
        final t = _parseTrak(d, b);
        if (t != null) {
          final r = trex[t.trackId];
          if (r != null) {
            t.trexDefaultDuration = r.defaultSampleDuration;
            t.trexDefaultSize = r.defaultSampleSize;
            t.trexDefaultFlags = r.defaultSampleFlags;
          }
          result.add(t);
        }
      }
    }
    return result;
  }

  static _TrackData? _parseTrak(Uint8List d, _BoxHeader trak) {
    final t = _TrackData();
    for (final b in _children(d, trak.payloadStart, trak.end)) {
      switch (b.type) {
        case 'tkhd':
          final bd = ByteData.sublistView(d, b.payloadStart, b.end);
          final version = bd.getUint8(0);
          var p = 4 + (version == 1 ? 16 : 8); // creation/modification
          t.trackId = bd.getUint32(p);
          p += 4; // track_ID
          p += 4; // reserved
          p += version == 1 ? 8 : 4; // duration
          p += 8; // reserved
          p += 8; // layer / alternate_group / volume / reserved
          t.matrix = Uint8List.fromList(
            d.sublist(b.payloadStart + p, b.payloadStart + p + 36),
          );
          p += 36;
          t.width = bd.getUint32(p);
          t.height = bd.getUint32(p + 4);
        case 'mdia':
          _parseMdia(d, b, t);
      }
    }
    if (t.trackId == 0 ||
        t.timescale == 0 ||
        t.stsdBytes == null ||
        t.hdlrBytes == null ||
        t.dinfBytes == null) {
      return null;
    }
    return t;
  }

  static void _parseMdia(Uint8List d, _BoxHeader mdia, _TrackData t) {
    for (final b in _children(d, mdia.payloadStart, mdia.end)) {
      switch (b.type) {
        case 'mdhd':
          final bd = ByteData.sublistView(d, b.payloadStart, b.end);
          final version = bd.getUint8(0);
          final p = 4 + (version == 1 ? 16 : 8);
          t.timescale = bd.getUint32(p);
          t.language = bd.getUint16(p + (version == 1 ? 12 : 8));
        case 'hdlr':
          t.handler = String.fromCharCodes(
            d.sublist(b.payloadStart + 8, b.payloadStart + 12),
          );
          t.hdlrBytes = Uint8List.fromList(d.sublist(b.start, b.end));
        case 'minf':
          for (final c in _children(d, b.payloadStart, b.end)) {
            switch (c.type) {
              case 'dinf':
                t.dinfBytes = Uint8List.fromList(d.sublist(c.start, c.end));
              case 'stbl':
                for (final s in _children(d, c.payloadStart, c.end)) {
                  if (s.type == 'stsd') {
                    t.stsdBytes = Uint8List.fromList(d.sublist(s.start, s.end));
                    _parseStsd(d, s, t);
                  }
                }
            }
          }
      }
    }
  }

  static void _parseStsd(Uint8List d, _BoxHeader stsd, _TrackData t) {
    // stsd: version/flags(4) entry_count(4) entries...
    var p = stsd.payloadStart + 4;
    final count = ByteData.sublistView(d, p, p + 4).getUint32(0);
    p += 4;
    if (count > 0 && p + 8 <= stsd.end) {
      t.codec = String.fromCharCodes(d.sublist(p + 4, p + 8));
    }
  }

  static void _parseMoof(
    Uint8List moof,
    int moofOffset,
    int moofHeaderSize,
    Map<int, _TrackData> byId,
  ) {
    for (final b in _children(moof, moofHeaderSize, moof.length)) {
      if (b.type != 'traf') {
        continue;
      }
      var trackId = 0;
      var baseDataOffset = moofOffset;
      var defaultDuration = 0;
      var defaultSize = 0;
      var defaultFlags = 0;
      var haveDuration = false;
      var haveSize = false;
      var haveFlags = false;
      var baseMediaDecodeTime = -1;
      final truns = <_BoxHeader>[];

      for (final c in _children(moof, b.payloadStart, b.end)) {
        switch (c.type) {
          case 'tfhd':
            final bd = ByteData.sublistView(moof, c.payloadStart, c.end);
            final flags = bd.getUint32(0) & 0xffffff;
            trackId = bd.getUint32(4);
            var p = 8;
            if (flags & 0x01 != 0) {
              baseDataOffset = bd.getUint64(p);
              p += 8;
            }
            if (flags & 0x02 != 0) {
              p += 4; // sample_description_index
            }
            if (flags & 0x08 != 0) {
              defaultDuration = bd.getUint32(p);
              haveDuration = true;
              p += 4;
            }
            if (flags & 0x10 != 0) {
              defaultSize = bd.getUint32(p);
              haveSize = true;
              p += 4;
            }
            if (flags & 0x20 != 0) {
              defaultFlags = bd.getUint32(p);
              haveFlags = true;
            }
          case 'tfdt':
            final bd = ByteData.sublistView(moof, c.payloadStart, c.end);
            baseMediaDecodeTime = bd.getUint8(0) == 1
                ? bd.getUint64(4)
                : bd.getUint32(4);
          case 'trun':
            truns.add(c);
        }
      }

      final track = byId[trackId];
      if (track == null) {
        continue;
      }
      if (!haveDuration && track.trexDefaultDuration > 0) {
        defaultDuration = track.trexDefaultDuration;
        haveDuration = true;
      }
      if (!haveSize && track.trexDefaultSize > 0) {
        defaultSize = track.trexDefaultSize;
        haveSize = true;
      }
      if (!haveFlags && track.trexDefaultFlags != 0) {
        defaultFlags = track.trexDefaultFlags;
        haveFlags = true;
      }
      if (baseMediaDecodeTime >= 0) {
        track.pendingDts = baseMediaDecodeTime;
      }

      for (final trun in truns) {
        final bd = ByteData.sublistView(moof, trun.payloadStart, trun.end);
        final version = bd.getUint8(0);
        final flags = bd.getUint32(0) & 0xffffff;
        final count = bd.getUint32(4);
        var p = 8;
        var dataOffset = 0;
        var firstSampleFlags = -1;
        if (flags & 0x01 != 0) {
          dataOffset = bd.getInt32(p);
          p += 4;
        }
        if (flags & 0x04 != 0) {
          firstSampleFlags = bd.getUint32(p);
          p += 4;
        }
        var sampleOffset = baseDataOffset + dataOffset;
        for (var i = 0; i < count; i++) {
          var duration = defaultDuration;
          var size = defaultSize;
          var sampleFlags = haveFlags ? defaultFlags : 0;
          if (i == 0 && firstSampleFlags >= 0) {
            sampleFlags = firstSampleFlags;
          }
          var cts = 0;
          if (flags & 0x100 != 0) {
            duration = bd.getUint32(p);
            p += 4;
          }
          if (flags & 0x200 != 0) {
            size = bd.getUint32(p);
            p += 4;
          }
          if (flags & 0x400 != 0) {
            sampleFlags = bd.getUint32(p);
            p += 4;
          }
          if (flags & 0x800 != 0) {
            cts = version == 1 ? bd.getInt32(p) : bd.getUint32(p);
            p += 4;
          }
          track.samples.add(
            _Sample(
              offset: sampleOffset,
              size: size,
              duration: duration,
              cts: cts,
              sync: sampleFlags & 0x10000 == 0,
              dts: track.pendingDts,
            ),
          );
          track.pendingDts += duration;
          sampleOffset += size;
        }
      }
    }
  }

  static List<_BoxHeader> _children(Uint8List d, int start, int end) {
    final out = <_BoxHeader>[];
    var off = start;
    while (off + 8 <= end) {
      final bd = ByteData.sublistView(d, off, off + 8);
      var size = bd.getUint32(0);
      final type = String.fromCharCodes(d.sublist(off + 4, off + 8));
      var headerSize = 8;
      if (size == 1) {
        if (off + 16 > end) {
          break;
        }
        size = ByteData.sublistView(d, off + 8, off + 16).getUint64(0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - off;
      }
      if (size < headerSize || off + size > end) {
        break;
      }
      out.add(_BoxHeader(type, off, size, headerSize));
      off += size;
    }
    return out;
  }
}

class _Trex {
  const _Trex({
    required this.defaultSampleDuration,
    required this.defaultSampleSize,
    required this.defaultSampleFlags,
  });

  final int defaultSampleDuration;
  final int defaultSampleSize;
  final int defaultSampleFlags;
}

class _Sample {
  const _Sample({
    required this.offset,
    required this.size,
    required this.duration,
    required this.cts,
    required this.sync,
    required this.dts,
  });

  final int offset;
  final int size;
  final int duration;
  final int cts;
  final bool sync;
  final int dts;

  int get ctsSigned => cts > 0x7fffffff ? cts - 0x100000000 : cts;
}

/// 源文件中的一条轨道。
class _TrackData {
  int trackId = 0;
  int timescale = 0;
  int language = 0x55c4; // und
  String handler = '';
  String codec = '';
  int width = 0;
  int height = 0;
  Uint8List? stsdBytes;
  Uint8List? dinfBytes;
  Uint8List? hdlrBytes;
  Uint8List matrix = Uint8List(0);
  int trexDefaultDuration = 0;
  int trexDefaultSize = 0;
  int trexDefaultFlags = 0;
  int pendingDts = 0;
  final List<_Sample> samples = <_Sample>[];
  int mediaDuration = 0;
  int durationUs = 0;

  bool get isVideo => handler == 'vide';

  void finish() {
    var dur = 0;
    for (final s in samples) {
      dur += s.duration;
    }
    mediaDuration = dur;
    durationUs = timescale == 0 ? 0 : dur * 1000000 ~/ timescale;
  }
}

/// 输出轨道：按块搬运样本并累积样本表。
class _OutTrack {
  _OutTrack(this.src, this.file);

  final _TrackData src;
  final RandomAccessFile file;

  var cursor = 0;
  var totalSamples = 0;
  var totalDurationTicks = 0;
  final List<int> sttsCounts = <int>[];
  final List<int> sttsDurations = <int>[];
  final List<int> cttsCounts = <int>[];
  final List<int> cttsOffsets = <int>[];
  final List<int> stssSamples = <int>[];
  final List<int> chunkOffsets = <int>[];
  final List<int> chunkCounts = <int>[];
  final List<int> sampleSizes = <int>[];

  bool get hasRemaining => cursor < src.samples.length;

  int get durationUs =>
      src.timescale == 0 ? 0 : totalDurationTicks * 1000000 ~/ src.timescale;

  int get mediaDuration => totalDurationTicks;

  int get totalSourceBytes {
    var total = 0;
    for (final s in src.samples) {
      total += s.size;
    }
    return total;
  }

  /// 下一个待写样本的解码时间（微秒，已归一化到轨道起点）。
  int get nextDtsUs {
    final first = src.samples.isEmpty ? 0 : src.samples.first.dts;
    return (src.samples[cursor].dts - first) * 1000000 ~/ src.timescale;
  }

  /// 写出一个数据块（同轨道连续的若干样本），返回搬运的字节数。
  Future<int> emitChunk(RandomAccessFile out, int mdatDataStart) async {
    final samples = src.samples;
    final startIndex = cursor;
    final targetTicks = Fmp4Muxer.chunkDurationUs * src.timescale ~/ 1000000;
    var expectedOffset = samples[startIndex].offset;
    var bytes = 0;
    var durTicks = 0;

    var i = startIndex;
    while (i < samples.length) {
      final s = samples[i];
      if (s.offset != expectedOffset) {
        break; // 源数据不连续，另起一块
      }
      if (i > startIndex && durTicks >= targetTicks) {
        break;
      }
      expectedOffset += s.size;
      bytes += s.size;
      durTicks += s.duration;
      i++;
    }

    final chunkOffset = await out.position(); // stco 记录的是文件绝对偏移
    await file.setPosition(samples[startIndex].offset);
    final data = await file.read(bytes);
    if (data.length != bytes) {
      throw Mp4MuxException('读取样本数据失败');
    }
    await out.writeFrom(data);

    chunkOffsets.add(chunkOffset);
    chunkCounts.add(i - startIndex);
    var prevDuration = -1;
    var prevCts = 0;
    for (var k = startIndex; k < i; k++) {
      final s = samples[k];
      sampleSizes.add(s.size);
      if (prevDuration < 0 || s.duration != prevDuration) {
        sttsDurations.add(s.duration);
        sttsCounts.add(1);
        prevDuration = s.duration;
      } else {
        sttsCounts[sttsCounts.length - 1]++;
      }
      final cts = s.ctsSigned;
      if (k == startIndex || cts != prevCts) {
        cttsOffsets.add(cts);
        cttsCounts.add(1);
        prevCts = cts;
      } else {
        cttsCounts[cttsCounts.length - 1]++;
      }
      if (s.sync) {
        stssSamples.add(k + 1);
      }
    }

    cursor = i;
    totalSamples += i - startIndex;
    totalDurationTicks += durTicks;
    return bytes;
  }

  Uint8List buildStbl() {
    final allSync = stssSamples.length == totalSamples;
    final hasCtts = cttsOffsets.any((e) => e != 0);
    final negativeCtts = cttsOffsets.any((e) => e < 0);

    return _box('stbl', (w) {
      w.bytes(src.stsdBytes!);
      w.box('stts', (w) {
        w.u32(0);
        w.u32(sttsCounts.length);
        for (var i = 0; i < sttsCounts.length; i++) {
          w.u32(sttsCounts[i]);
          w.u32(sttsDurations[i]);
        }
      });
      if (hasCtts) {
        w.box('ctts', (w) {
          w.u32(negativeCtts ? 0x01000000 : 0);
          w.u32(cttsCounts.length);
          for (var i = 0; i < cttsCounts.length; i++) {
            w.u32(cttsCounts[i]);
            if (negativeCtts) {
              w.i32(cttsOffsets[i]);
            } else {
              w.u32(cttsOffsets[i]);
            }
          }
        });
      }
      if (!allSync) {
        w.box('stss', (w) {
          w.u32(0);
          w.u32(stssSamples.length);
          for (final s in stssSamples) {
            w.u32(s);
          }
        });
      }
      w.box('stsc', (w) {
        w.u32(0);
        final firstChunks = <int>[];
        final counts = <int>[];
        for (var i = 0; i < chunkCounts.length; i++) {
          if (counts.isEmpty || counts.last != chunkCounts[i]) {
            firstChunks.add(i + 1);
            counts.add(chunkCounts[i]);
          }
        }
        w.u32(counts.length);
        for (var i = 0; i < counts.length; i++) {
          w.u32(firstChunks[i]);
          w.u32(counts[i]);
          w.u32(1); // sample_description_index
        }
      });
      w.box('stsz', (w) {
        w.u32(0);
        w.u32(0);
        w.u32(sampleSizes.length);
        for (final s in sampleSizes) {
          w.u32(s);
        }
      });
      w.box('stco', (w) {
        w.u32(0);
        w.u32(chunkOffsets.length);
        for (final o in chunkOffsets) {
          w.u32(o);
        }
      });
    });
  }
}
