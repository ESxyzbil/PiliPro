import 'dart:io';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 把文件放到「系统共享的下载目录」，让用户真正拿得到文件。
///
/// Android 上应用私有外置目录（`Android/data/包名/`）自 API 30 起既不能被 PC 侧 adb
/// 读取，普通文件管理器也读不到；故导出的大文件默认写应用目录后，再经此桥接复制到
/// 公共下载目录（`Download/应用名/`）。
abstract final class SharedStorage {
  static const _channel = MethodChannel('com.example.piliplus/media_store');

  /// 公共下载目录下的子目录名
  static String get _subDir => Constants.appName;

  /// 把 [sourcePath] 复制到公共下载目录，返回落盘位置描述；失败返回 null。
  static Future<SharedCopyResult?> copyToDownloads(
    String sourcePath, {
    String? displayName,
  }) async {
    final src = File(sourcePath);
    final exists = src.existsSync();
    debugPrint(
      '[SharedStorage] request: src=$sourcePath exists=$exists isAndroid=${Platform.isAndroid}',
    );
    if (!exists) return null;
    final name = displayName ?? p.basename(sourcePath);

    if (Platform.isAndroid) {
      try {
        debugPrint('[SharedStorage] invoking channel media_store …');
        final res = await _channel.invokeMapMethod<String, dynamic>(
          'copyToDownloads',
          {
            'sourcePath': sourcePath,
            'displayName': name,
            'subDir': _subDir,
          },
        );
        debugPrint('[SharedStorage] channel returned: $res');
        if (res == null || res['ok'] != true) {
          debugPrint(
            '[SharedStorage] copy failed: ' +
                (res?['error']?.toString() ?? 'unknown'),
          );
          return null;
        }
        debugPrint(
          '[SharedStorage] copied via ' +
              (res['method']?.toString() ?? '?') +
              ' -> ' +
              (res['uri']?.toString() ?? ''),
        );
        return SharedCopyResult(
          displayPath: 'Download/$_subDir/$name',
          uri: res['uri'] as String?,
          method: res['method'] as String?,
          size: (res['size'] as num?)?.toInt() ?? await src.length(),
        );
      } on PlatformException catch (e) {
        debugPrint(
          '[SharedStorage] PlatformException: ' + e.message.toString(),
        );
        return null;
      } on MissingPluginException catch (e) {
        debugPrint(
          '[SharedStorage] MissingPluginException: ' + e.toString(),
        );
        return null;
      }
    }

    // 桌面端：直接落到系统「下载」目录
    try {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
      final dir = Directory(
        home.isEmpty
            ? p.join(appSupportDirPath, 'export')
            : p.join(home, 'Downloads', _subDir),
      );
      if (!dir.existsSync()) await dir.create(recursive: true);
      final dst = p.join(dir.path, name);
      await src.copy(dst);
      return SharedCopyResult(
        displayPath: dst,
        size: await File(dst).length(),
      );
    } catch (_) {
      return null;
    }
  }
}

class SharedCopyResult {
  final String displayPath;
  final String? uri;

  /// 落盘方式：mediastore（系统媒体库）/ direct（直写共享目录）
  final String? method;
  final int size;

  const SharedCopyResult({
    required this.displayPath,
    this.uri,
    this.method,
    required this.size,
  });
}
