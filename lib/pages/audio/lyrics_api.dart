import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/utils/id_utils.dart';

enum LyricsSource {
  netease('网易云音乐', '☁️'),
  kugou('酷狗音乐', '🐶'),
  douyin('汽水音乐', '💧'),
  bilibili_cc('B站CC字幕', '📄');

  final String label;
  final String icon;
  const LyricsSource(this.label, this.icon);
}

class LyricsLine {
  final Duration time;
  final String text;
  LyricsLine(this.time, this.text);
}

/// 歌词搜索结果（单条歌曲）
class LyricsSearchItem {
  final String title;
  final String artist;
  final String subtitle; // 专辑/时长等补充信息

  // 各平台取歌词需要的参数
  final int? neteaseSongId;
  final String? kugouFileHash;
  final String? kugouId; // candidate id
  final String? kugouAccesskey;
  final String? qishuiId; // 汽水音乐 item_id

  const LyricsSearchItem({
    required this.title,
    required this.artist,
    this.subtitle = '',
    this.neteaseSongId,
    this.kugouFileHash,
    this.kugouId,
    this.kugouAccesskey,
    this.qishuiId,
  });
}

class LyricsResult {
  final String source;
  final List<LyricsLine>? syncedLines;
  final String? plainText;
  final String? error;

  LyricsResult({
    required this.source,
    this.syncedLines,
    this.plainText,
    this.error,
  });

  bool get isSuccess => error == null;

  int getCurrentLineIndex(Duration position) {
    if (syncedLines == null || syncedLines!.isEmpty) return -1;
    int idx = syncedLines!.length - 1;
    for (int i = 0; i < syncedLines!.length; i++) {
      if (position < syncedLines![i].time) {
        idx = i - 1;
        break;
      }
    }
    return idx >= 0 ? idx : 0;
  }
}

/// 解析 LRC 格式歌词文本 -> List<LyricsLine>
List<LyricsLine>? parseLrc(String lrcText) {
  try {
    final lines = <LyricsLine>[];
    final regex = RegExp(r'\[(\d{2,3}):(\d{2})[\.:](\d{2,3})\](.*)');
    for (final line in lrcText.split('\n')) {
      final match = regex.firstMatch(line.trim());
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final millis = int.parse(match.group(3)!.padRight(3, '0').substring(0, 3));
        final text = match.group(4)!.trim();
        if (text.isNotEmpty) {
          lines.add(LyricsLine(
            Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
            text,
          ));
        }
      }
    }
    return lines.isNotEmpty ? lines : null;
  } catch (_) {
    return null;
  }
}

/// HTTP GET 请求
Future<String> _httpGet(Uri uri, {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    if (headers != null) {
      headers.forEach((k, v) => request.headers.set(k, v));
    }
    final response = await request.close().timeout(const Duration(seconds: 8));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return body;
  } finally {
    client.close();
  }
}

// ═══════════════════════════════════════════
//  网易云音乐
// ═══════════════════════════════════════════

Future<List<LyricsSearchItem>> searchNetease(String keyword, {int page = 1, int limit = 20}) async {
  try {
    final offset = (page - 1) * limit;
    final searchUri = Uri.parse(
      'https://music.163.com/api/search/get/web?csrf_token=hlpretag=&hlposttag=&s=${Uri.encodeComponent(keyword)}&type=1&offset=$offset&total=true&limit=$limit',
    );
    final searchBody = await _httpGet(searchUri);
    final searchData = jsonDecode(searchBody);
    final songs = searchData['result']?['songs'] as List?;
    if (songs == null || songs.isEmpty) return [];
    return songs.map((s) {
      return LyricsSearchItem(
        title: s['name'] as String? ?? '',
        artist: (s['artists'] as List?)?.map((a) => a['name']).join(', ') ?? '',
        subtitle: s['album']?['name'] as String? ?? '',
        neteaseSongId: s['id'] as int?,
      );
    }).toList();
  } catch (_) {
    return [];
  }
}

Future<LyricsResult> fetchFromNetease(LyricsSearchItem item) async {
  final songId = item.neteaseSongId;
  if (songId == null) {
    return LyricsResult(source: '网易云音乐', error: '缺少歌曲标识');
  }
  return _neteaseFetchById(songId);
}

Future<LyricsResult> fetchFromNeteaseByKeyword(String keyword) async {
  try {
    final items = await searchNetease(keyword);
    if (items.isEmpty) {
      return LyricsResult(source: '网易云音乐', error: '未找到歌曲');
    }
    final songId = items.first.neteaseSongId;
    if (songId == null) {
      return LyricsResult(source: '网易云音乐', error: '无法获取歌曲信息');
    }
    return await _neteaseFetchById(songId);
  } catch (e) {
    return LyricsResult(source: '网易云音乐', error: e.toString());
  }
}

Future<LyricsResult> _neteaseFetchById(int songId) async {
  try {
    final lyricUri = Uri.parse(
      'https://music.163.com/api/song/lyric?id=$songId&lv=1&kv=1&tv=-1',
    );
    final lyricBody = await _httpGet(lyricUri);
    final lyricData = jsonDecode(lyricBody);
    final lrcObj = lyricData['lrc'] as Map?;
    if (lrcObj == null) {
      return LyricsResult(source: '网易云音乐', error: '无歌词');
    }
    final lrcText = lrcObj['lyric'] as String?;
    if (lrcText == null || lrcText.isEmpty) {
      return LyricsResult(source: '网易云音乐', error: '无歌词');
    }
    final parsed = parseLrc(lrcText);
    return LyricsResult(
      source: '网易云音乐',
      syncedLines: parsed,
      plainText: lrcText,
    );
  } catch (e) {
    return LyricsResult(source: '网易云音乐', error: e.toString());
  }
}

// ═══════════════════════════════════════════
//  酷狗音乐
// ═══════════════════════════════════════════

Future<List<LyricsSearchItem>> searchKugou(String keyword, {int page = 1, int limit = 20}) async {
  try {
    final searchUri = Uri.parse(
      'https://songsearch.kugou.com/song_search_v2?keyword=${Uri.encodeComponent(keyword)}&page=$page&pagesize=$limit',
    );
    final searchBody = await _httpGet(searchUri);
    final searchData = jsonDecode(searchBody);
    final lists = searchData['data']?['lists'] as List?;
    if (lists == null || lists.isEmpty) return [];
    return lists.map((s) {
      return LyricsSearchItem(
        title: s['SongName'] as String? ?? '',
        artist: s['SingerName'] as String? ?? '',
        subtitle: s['AlbumName'] as String? ?? '',
        kugouFileHash: s['FileHash'] as String?,
      );
    }).toList();
  } catch (_) {
    return [];
  }
}

Future<LyricsResult> fetchFromKugou(LyricsSearchItem item) async {
  final fileHash = item.kugouFileHash;
  if (fileHash == null || fileHash.isEmpty) {
    return LyricsResult(source: '酷狗音乐', error: '缺少歌曲标识');
  }
  return _kugouFetchByHash(fileHash);
}

Future<LyricsResult> fetchFromKugouByKeyword(String keyword) async {
  try {
    final items = await searchKugou(keyword);
    if (items.isEmpty) {
      return LyricsResult(source: '酷狗音乐', error: '未找到歌曲');
    }
    final fileHash = items.first.kugouFileHash;
    if (fileHash == null) {
      return LyricsResult(source: '酷狗音乐', error: '无法获取歌曲信息');
    }
    return await _kugouFetchByHash(fileHash);
  } catch (e) {
    return LyricsResult(source: '酷狗音乐', error: e.toString());
  }
}

Future<LyricsResult> _kugouFetchByHash(String fileHash) async {
  try {
    final candidateUri = Uri.parse(
      'https://krcs.kugou.com/search?ver=1&hash=$fileHash&key=${fileHash.substring(0, 16)}&man=yes',
    );
    final candidateBody = await _httpGet(candidateUri);
    final candidateData = jsonDecode(candidateBody);
    final candidates = candidateData['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      return LyricsResult(source: '酷狗音乐', error: '无歌词');
    }
    final best = candidates.first;
    final id = best['id'];
    final accesskey = best['accesskey'];

    final downloadUri = Uri.parse(
      'https://krcs.kugou.com/download?ver=1&id=$id&accesskey=$accesskey&fmt=lrc',
    );
    final downloadBody = await _httpGet(downloadUri);
    final downloadData = jsonDecode(downloadBody);
    final contentB64 = downloadData['content'] as String?;
    if (contentB64 == null || contentB64.isEmpty) {
      return LyricsResult(source: '酷狗音乐', error: '歌词内容为空');
    }
    final lrcText = utf8.decode(base64.decode(contentB64));
    final parsed = parseLrc(lrcText);
    return LyricsResult(
      source: '酷狗音乐',
      syncedLines: parsed,
      plainText: lrcText,
    );
  } catch (e) {
    return LyricsResult(source: '酷狗音乐', error: e.toString());
  }
}

// ═══════════════════════════════════════════
//  汽水音乐（抖音音乐）
// ═══════════════════════════════════════════

const String _qishuiSearchApi = 'https://api-vehicle.volcengine.com/v2/search/type';
const String _qishuiDetailApi = 'https://api-vehicle.volcengine.com/v2/custom/contents';

Future<List<LyricsSearchItem>> searchQishui(String keyword,
    {int page = 1, int limit = 20}) async {
  try {
    final offset = (page - 1) * limit;
    final searchUri = Uri.parse(
      '$_qishuiSearchApi?keyword=${Uri.encodeComponent(keyword)}'
      '&search_type=music&limit=$limit&real_offset=$offset&search_source=qishui',
    );
    final searchBody = await _httpGet(searchUri);
    final searchData = jsonDecode(searchBody);
    final list = searchData['data']?['list'] as List?;
    if (list == null || list.isEmpty) return [];
    return list.map((s) {
      final author = s['author_info'] as Map?;
      final album = s['album_info'] as Map?;
      return LyricsSearchItem(
        title: s['title'] as String? ?? '',
        artist: author?['name'] as String? ?? '',
        subtitle: album?['name'] as String? ?? '',
        qishuiId: s['item_id']?.toString(),
      );
    }).toList();
  } catch (_) {
    return [];
  }
}

Future<LyricsResult> fetchFromQishui(LyricsSearchItem item) async {
  final songId = item.qishuiId;
  if (songId == null || songId.isEmpty) {
    return LyricsResult(source: '汽水音乐', error: '缺少歌曲标识');
  }
  return _qishuiFetchById(songId);
}

Future<LyricsResult> fetchFromQishuiByKeyword(String keyword) async {
  try {
    final items = await searchQishui(keyword);
    if (items.isEmpty) {
      return LyricsResult(source: '汽水音乐', error: '未找到歌曲');
    }
    final songId = items.first.qishuiId;
    if (songId == null) {
      return LyricsResult(source: '汽水音乐', error: '无法获取歌曲信息');
    }
    return await _qishuiFetchById(songId);
  } catch (e) {
    return LyricsResult(source: '汽水音乐', error: e.toString());
  }
}

Future<LyricsResult> _qishuiFetchById(String songId) async {
  try {
    final detailUri = Uri.parse(
      '$_qishuiDetailApi?sources=qishui&need_author=true&need_album=true'
      '&need_ugc=true&need_stat=true&item_ids=$songId',
    );
    final detailBody = await _httpGet(detailUri);
    final detailData = jsonDecode(detailBody);
    final list = detailData['data']?['list'] as List?;
    if (list == null || list.isEmpty) {
      return LyricsResult(source: '汽水音乐', error: '歌曲详情为空');
    }
    final lyricInfo = list.first['lyric_info'] as Map?;
    final lrcText = lyricInfo?['lyric_text'] as String?;
    if (lrcText == null || lrcText.isEmpty) {
      return LyricsResult(source: '汽水音乐', error: '无歌词');
    }
    final parsed = parseLrc(lrcText);
    return LyricsResult(
      source: '汽水音乐',
      syncedLines: parsed,
      plainText: lrcText,
    );
  } catch (e) {
    return LyricsResult(source: '汽水音乐', error: e.toString());
  }
}

// ═══════════════════════════════════════════
//  统一搜索接口
// ═══════════════════════════════════════════

/// 搜索所有平台，返回 {来源 → 搜索结果列表}
Future<Map<LyricsSource, List<LyricsSearchItem>>> searchAllPlatforms(String keyword) async {
  final results = <LyricsSource, List<LyricsSearchItem>>{
    LyricsSource.netease: await searchNetease(keyword),
    LyricsSource.kugou: await searchKugou(keyword),
    LyricsSource.douyin: await searchQishui(keyword),
  };
  return results;
}

/// 对单个搜索结果项取歌词
Future<LyricsResult> fetchLyricsForItem(LyricsSource source, LyricsSearchItem item) {
  switch (source) {
    case LyricsSource.netease:
      return fetchFromNetease(item);
    case LyricsSource.kugou:
      return fetchFromKugou(item);
    case LyricsSource.douyin:
      return fetchFromQishui(item);
    case LyricsSource.bilibili_cc:
      return Future.value(LyricsResult(source: source.label, error: 'B站CC字幕不支持此方式获取'));
  }
}

/// 按关键词搜索并自动取第一个匹配项歌词（兼容旧接口）
Future<LyricsResult> searchAndPickFirst(LyricsSource source, String keyword) {
  switch (source) {
    case LyricsSource.netease:
      return fetchFromNeteaseByKeyword(keyword);
    case LyricsSource.kugou:
      return fetchFromKugouByKeyword(keyword);
    case LyricsSource.douyin:
      return fetchFromQishuiByKeyword(keyword);
    case LyricsSource.bilibili_cc:
      return Future.value(LyricsResult(source: source.label, error: 'B站CC字幕不支持此方式获取'));
  }
}

/// 统一搜索接口：所有来源并行搜索 + 取第一首歌词
Future<Map<LyricsSource, LyricsResult>> searchAllSources(String keyword) async {
  final results = <LyricsSource, LyricsResult>{};
  final futures = <MapEntry<LyricsSource, Future<LyricsResult>>>[
    MapEntry(LyricsSource.netease, searchAndPickFirst(LyricsSource.netease, keyword)),
    MapEntry(LyricsSource.kugou, searchAndPickFirst(LyricsSource.kugou, keyword)),
    MapEntry(LyricsSource.douyin, searchAndPickFirst(LyricsSource.douyin, keyword)),
  ];
  for (final entry in futures) {
    results[entry.key] = await entry.value;
  }
  return results;
}

// ═══════════════════════════════════════════
//  B站 CC字幕
// ═══════════════════════════════════════════

/// 从 B站视频接口获取字幕 URL
/// 优先用 playInfo（WBI 签名），回退到 view 接口
Future<String?> _getBilibiliSubtitleUrl(int aid, int cid) async {
  // 尝试 A: playInfo（需要 WBI 签名）
  try {
    final playInfoRes = await VideoHttp.playInfo(aid: aid.toString(), cid: cid);
    if (playInfoRes case Success(:final response)) {
      final url = response.subtitle?.subtitles?.firstWhereOrNull(
        (s) => !s.isAi,
      )?.subtitleUrl;
      if (url != null && url.isNotEmpty) return url;
    }
  } catch (_) {}

  // 尝试 B: view 接口（免签名）
  try {
    final bvid = IdUtils.av2bv(aid);
    final viewBody = await _httpGet(Uri.parse(
      'https://api.bilibili.com/x/web-interface/view?bvid=$bvid',
    ));
    final viewData = jsonDecode(viewBody);
    if (viewData['code'] == 0) {
      final list = viewData['data']?['subtitle']?['list'] as List?;
      if (list != null) {
        for (final item in list) {
          final url = item['subtitle_url'] as String?;
          if (url != null && url.isNotEmpty) {
            return url;
          }
        }
      }
    }
  } catch (_) {}

  return null;
}

/// 从字幕 URL 直取 JSON body 解析（不依赖 vttSubtitles）
Future<List<LyricsLine>?> _fetchSubtitleJsonDirect(String subtitleUrl) async {
  try {
    final url = subtitleUrl.startsWith('//') ? 'https:$subtitleUrl' : subtitleUrl;
    final client = HttpClient();
    client.userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('Referer', 'https://www.bilibili.com');
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join();
    client.close();
    final json = jsonDecode(body);
    final list = json['body'] as List?;
    if (list == null || list.isEmpty) return null;
    final lines = <LyricsLine>[];
    for (final item in list) {
      final from = (item['from'] as num).toDouble();
      final content = item['content'] as String?;
      if (content != null && content.trim().isNotEmpty) {
        final sec = from ~/ 1;
        final ms = ((from - sec) * 1000).round();
        lines.add(LyricsLine(
          Duration(seconds: sec, milliseconds: ms),
          content.trim(),
        ));
      }
    }
    return lines.isNotEmpty ? lines : null;
  } catch (_) {
    return null;
  }
}

/// 从字幕 URL 下载 VTT 文本 / 直解析 JSON body
Future<List<LyricsLine>?> _parseBilibiliSubtitleJson(String subtitleUrl) async {
  if (subtitleUrl.isEmpty) return null;

  // 尝试 A: 用现有的 vttSubtitles（走 Request 包装，含 WBI/auth 等）
  try {
    final res = await VideoHttp.vttSubtitles(subtitleUrl);
    if (res != null && res.isNotEmpty) {
      // vttSubtitles 返回 VTT 格式文本：
      //   WEBVTT\n\n
      //   MM:SS.mmm --> MM:SS.mmm\n   (or HH:MM:SS.mmm --> HH:MM:SS.mmm)
      //   字幕文本\n\n
      final lines = <LyricsLine>[];
      // HH:MM:SS.mmm
      final vttRegexFull = RegExp(
          r'(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s*-->\s*\d{2}:\d{2}:\d{2}\.\d{3}\s*\n(.*)',
          multiLine: true);
      // MM:SS.mmm (no hours)
      final vttRegexShort = RegExp(
          r'(\d{2}):(\d{2})\.(\d{3})\s*-->\s*\d{2}:\d{2}\.\d{3}\s*\n(.*)',
          multiLine: true);
      for (final match in vttRegexFull.allMatches(res)) {
        final h = int.parse(match.group(1)!);
        final m = int.parse(match.group(2)!);
        final s = int.parse(match.group(3)!);
        final ms = int.parse(match.group(4)!);
        final text = match.group(5)!.trimRight();
        if (text.isNotEmpty) {
          lines.add(LyricsLine(
            Duration(hours: h, minutes: m, seconds: s, milliseconds: ms),
            text,
          ));
        }
      }
      if (lines.isEmpty) {
        for (final match in vttRegexShort.allMatches(res)) {
          final m = int.parse(match.group(1)!);
          final s = int.parse(match.group(2)!);
          final ms = int.parse(match.group(3)!);
          final text = match.group(4)!.trimRight();
          if (text.isNotEmpty) {
            lines.add(LyricsLine(
              Duration(minutes: m, seconds: s, milliseconds: ms),
              text,
            ));
          }
        }
      }
      if (lines.isNotEmpty) return lines;
    }
  } catch (_) {}

  // 尝试 B: vttSubtitles 失败（或返回空），直取 JSON body
  return _fetchSubtitleJsonDirect(subtitleUrl);
}

/// 取 B站 CC 字幕（基于 aid + cid）
Future<LyricsResult> fetchBilibiliCc(int aid, int cid) async {
  try {
    final subtitleUrl = await _getBilibiliSubtitleUrl(aid, cid);
    if (subtitleUrl == null || subtitleUrl.isEmpty) {
      return LyricsResult(source: 'B站CC字幕', error: '无可用字幕');
    }
    final lines = await _parseBilibiliSubtitleJson(subtitleUrl);
    if (lines == null || lines.isEmpty) {
      return LyricsResult(source: 'B站CC字幕', error: '字幕内容为空');
    }
    return LyricsResult(source: 'B站CC字幕', syncedLines: lines);
  } catch (e) {
    return LyricsResult(source: 'B站CC字幕', error: e.toString());
  }
}
