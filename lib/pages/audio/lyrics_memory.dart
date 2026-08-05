import 'dart:convert';

import 'package:PiliPlus/pages/audio/lyrics_api.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

/// 歌词记忆匹配：记住某首歌选定的歌词源和歌曲
class LyricsMemory {
  static const _key = 'lyrics_remembered_v2';

  /// 数据格式：
  /// "音频标题|音频艺术家": {
  ///   "source":"netease|kugou",
  ///   "songTitle":"...",
  ///   "songArtist":"...",
  ///   "subtitle":"...",
  ///   "neteaseSongId":12345,
  ///   "kugouFileHash":"...",
  ///   "kugouId":"...",
  ///   "kugouAccesskey":"..."
  /// }
  static Map<String, Map<String, dynamic>> _load() {
    final raw = GStorage.setting.get(_key) as String?;
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
    } catch (_) {
      return {};
    }
  }

  static void _save(Map<String, Map<String, dynamic>> data) {
    GStorage.setting.put(_key, jsonEncode(data));
  }

  /// 生成音频标识键（区分不同平台同名歌曲）
  static String _audioKey(String title, String artist) {
    return '${title.trim()}|${artist.trim()}';
  }

  /// 查询当前音频是否有已记忆的歌词匹配
  /// 返回完整的 [LyricsSearchItem]（含平台 ID），可直接用于取歌词
  static (LyricsSource source, LyricsSearchItem item)? getRemembered(
    String audioTitle,
    String audioArtist,
  ) {
    final data = _load();
    final key = _audioKey(audioTitle, audioArtist);
    final entry = data[key];
    if (entry == null) return null;
    try {
      final source = LyricsSource.values.firstWhere(
        (s) => s.name == entry['source'],
      );
      return (
        source,
        LyricsSearchItem(
          title: entry['songTitle'] as String? ?? '',
          artist: entry['songArtist'] as String? ?? '',
          subtitle: entry['subtitle'] as String? ?? '',
          neteaseSongId: entry['neteaseSongId'] as int?,
          kugouFileHash: entry['kugouFileHash'] as String?,
          kugouId: entry['kugouId'] as String?,
          kugouAccesskey: entry['kugouAccesskey'] as String?,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// 记忆：当前音频匹配到 [source] 的 [item]
  static void remember(
    String audioTitle,
    String audioArtist,
    LyricsSource source,
    LyricsSearchItem item,
  ) {
    final data = _load();
    final key = _audioKey(audioTitle, audioArtist);
    data[key] = {
      'source': source.name,
      'songTitle': item.title,
      'songArtist': item.artist,
      'subtitle': item.subtitle,
      'neteaseSongId': item.neteaseSongId,
      'kugouFileHash': item.kugouFileHash,
      'kugouId': item.kugouId,
      'kugouAccesskey': item.kugouAccesskey,
    };
    _save(data);
  }

  /// 移除记忆
  static void forget(String audioTitle, String audioArtist) {
    final data = _load();
    final key = _audioKey(audioTitle, audioArtist);
    data.remove(key);
    _save(data);
  }

  /// 判断 [item] 是否是当前音频已记忆的匹配项
  static bool isRemembered(
    String audioTitle,
    String audioArtist,
    LyricsSource source,
    LyricsSearchItem item,
  ) {
    final data = _load();
    final key = _audioKey(audioTitle, audioArtist);
    final entry = data[key];
    if (entry == null) return false;
    return entry['source'] == source.name &&
        entry['songTitle'] == item.title &&
        entry['songArtist'] == item.artist;
  }

  /// 记忆：当前音频使用 CC 字幕
  static void rememberCc(String audioTitle, String audioArtist) =>
      rememberSource(audioTitle, audioArtist, LyricsSource.bilibili_cc);

  /// 检查是否记忆了 CC 字幕
  static bool isRememberedCc(String audioTitle, String audioArtist) =>
      isRememberedSource(audioTitle, audioArtist, LyricsSource.bilibili_cc);

  /// 记忆：当前音频使用指定源（CC 字幕/弹幕歌词等不进搜索的源）
  static void rememberSource(
    String audioTitle,
    String audioArtist,
    LyricsSource source,
  ) {
    final data = _load();
    final key = _audioKey(audioTitle, audioArtist);
    data[key] = {
      'source': source.name,
      'songTitle': '',
      'songArtist': '',
    };
    _save(data);
  }

  /// 检查是否记忆了指定源
  static bool isRememberedSource(
    String audioTitle,
    String audioArtist,
    LyricsSource source,
  ) {
    final data = _load();
    final key = _audioKey(audioTitle, audioArtist);
    final entry = data[key];
    return entry != null && entry['source'] == source.name;
  }

  /// 全局默认使用 CC 字幕
  static bool get defaultCc => GStorage.setting.get(
        SettingBoxKey.defaultCcLyrics,
        defaultValue: false,
      ) as bool;

  static set defaultCc(bool value) =>
      GStorage.setting.put(SettingBoxKey.defaultCcLyrics, value);

  /// 全局默认使用弹幕歌词
  static bool get defaultDanmaku => GStorage.setting.get(
        SettingBoxKey.defaultDanmakuLyrics,
        defaultValue: false,
      ) as bool;

  static set defaultDanmaku(bool value) =>
      GStorage.setting.put(SettingBoxKey.defaultDanmakuLyrics, value);
}
