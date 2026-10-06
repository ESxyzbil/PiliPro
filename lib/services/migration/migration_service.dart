import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/models/migration/migration_manifest.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/migration/shared_storage.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:archive/archive_io.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

typedef MigrateProgress = void Function(double value, String label);

/// 导出结果
class MigrationExportResult {
  final String path;
  final int totalSize;
  final int entries;
  final int elapsedMs;

  const MigrationExportResult({
    required this.path,
    required this.totalSize,
    required this.entries,
    required this.elapsedMs,
  });
}

/// 导入预检结果（尚未落盘）
class MigrationPreview {
  final MigrationManifest manifest;
  final String archivePath;

  /// 解包暂存目录
  final String stagingDir;

  final bool hasHive;
  final bool hasAssets;
  final bool hasModels;
  final bool hasDownloads;
  final int fileCount;
  final int totalSize;
  final List<String> warnings;

  const MigrationPreview({
    required this.manifest,
    required this.archivePath,
    required this.stagingDir,
    required this.hasHive,
    required this.hasAssets,
    required this.hasModels,
    required this.hasDownloads,
    required this.fileCount,
    required this.totalSize,
    required this.warnings,
  });

  /// 由清单生成可读的覆盖面摘要
  List<String> get summary {
    final list = <String>[];
    final hiveNames = manifest
        .byKind('hive')
        .map((e) => p.basenameWithoutExtension(e.path))
        .toList();
    if (hiveNames.isNotEmpty) {
      list.add('数据箱 ${hiveNames.length} 个：${hiveNames.join('、')}');
    }
    if (hasAssets) list.add('自定义背景与字体');
    if (hasModels) list.add('识别模型包');
    if (hasDownloads) {
      final n = manifest
          .byKind('download')
          .where((e) => e.path.endsWith('entry.json'))
          .length;
      list.add(n > 0 ? '已缓存视频 $n 个条目' : '已缓存视频');
    }
    return list;
  }
}

/// 导入执行结果
class MigrationApplyResult {
  final bool success;
  final String? backupDir;
  final String message;

  const MigrationApplyResult({
    required this.success,
    this.backupDir,
    required this.message,
  });
}

abstract final class MigrationService {
  static bool _busy = false;

  static bool get isBusy => _busy;

  static Directory get stagingDir =>
      Directory(p.join(appSupportDirPath, 'migration_staging'));

  /// 统一的包内路径分隔符（ZIP 规范使用正斜杠）
  static String _zipPath(String path) => path.replaceAll(_backslash, '/');

  static const _backslash = '\\';

  static String _nativePath(String path) =>
      Platform.isWindows ? path.replaceAll('/', _backslash) : path;

  // ───────────────────────────── 体积预估 ─────────────────────────────

  /// 统计各范围的文件总量（仅用于界面预估，不做完整哈希）
  static Future<int> estimateSize(List<String> scopes) async {
    var total = 0;
    if (_needHive(scopes)) {
      final dir = Directory(GStorage.hiveDirPath);
      if (dir.existsSync()) total += await _dirSize(dir);
    }
    if (scopes.contains(MigrationScope.assets)) {
      // 背景图不止 globalBg：设备上还可能有 homeBg/mineBg（设置里各自引用），
      // 故整目录打包，避免只搬一张导致其它背景丢失（2026-10-05 复核发现）。
      final bgDir = Directory(p.join(appSupportDirPath, 'background'));
      if (bgDir.existsSync()) total += await _dirSize(bgDir);
      total += await _fileSize(p.join(appSupportDirPath, 'customFont.otf'));
    }
    if (scopes.contains(MigrationScope.models)) {
      for (final name in const ['ocr_models', 'ocr_packs', 'asr_packs']) {
        final dir = Directory(p.join(appSupportDirPath, name));
        if (dir.existsSync()) total += await _dirSize(dir);
      }
    }
    if (scopes.contains(MigrationScope.downloads)) {
      final dir = Directory(downloadPath);
      if (dir.existsSync()) total += await _dirSize(dir, skip: _isMigrationPackage);
    }
    return total;
  }

  static bool _needHive(List<String> scopes) =>
      scopes.contains(MigrationScope.light) ||
      scopes.contains(MigrationScope.standard);

  /// 轻量范围只导出「设置」与「视频设置」两箱
  static List<String> _hiveBoxNames(List<String> scopes, List<String> all) {
    if (scopes.contains(MigrationScope.standard)) return all;
    return all.where((k) => k == 'setting' || k == 'video').toList();
  }

  /// 是否为迁移包自身（导出产物）。它正落在应用下载目录里，
  /// 若不排除，勾选「已缓存视频」时会把上一版包也算进体积、甚至打包进去。
  static bool _isMigrationPackage(String path) {
    final name = p.basename(path).toLowerCase();
    return name.startsWith('piliplus_migration') && name.endsWith('.zip');
  }

  static Future<int> _dirSize(
    Directory dir, {
    bool Function(String path)? skip,
  }) async {
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File && !e.path.endsWith('.lock')) {
        if (skip != null && skip(e.path)) continue;
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }

  static Future<int> _fileSize(String path) async {
    final file = File(path);
    if (!file.existsSync()) return 0;
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  // ───────────────────────────── 导出 ─────────────────────────────

  /// 导出迁移包（单文件；媒体用 STORE 不压缩，避免无谓的 CPU 与时间开销）
  static Future<MigrationExportResult> export({
    required List<String> scopes,
    bool toSharedStorage = false,
    MigrateProgress? onProgress,
  }) async {
    if (_busy) throw StateError('已有迁移任务在进行中');
    _busy = true;
    final started = DateTime.now();
    final tmpFile = File(
      p.join(
        tmpDirPath,
        'piliplus_migration_${DateTime.now().millisecondsSinceEpoch}.zip',
      ),
    );
    debugPrint('[Migration] tmpFile=${tmpFile.path}');
    ZipFileEncoder? encoder;
    try {
      // 1. 压实数据箱：compact() 会把数据重写为最新状态，复制出的文件即完整可用。
      //    注意：这里**不能** close——GStorage 的箱是 static late final，关掉后无法重开，
      //    会让应用此后任何设置读写都抛 "Box has already been closed"（2026-10-04 实机踩到）。
      if (_needHive(scopes)) {
        onProgress?.call(0.01, '正在整理数据…');
        await GStorage.compact();
      }

      // 2. 收集待打包文件
      final hiveFiles = <String, String>{};
      if (_needHive(scopes)) {
        final dir = Directory(GStorage.hiveDirPath);
        if (dir.existsSync()) {
          await for (final e in dir.list(followLinks: false)) {
            if (e is File && e.path.endsWith('.hive')) {
              hiveFiles[p.basenameWithoutExtension(e.path)] = e.path;
            }
          }
        }
      }
      final boxNames = _hiveBoxNames(scopes, hiveFiles.keys.toList());

      final downloads = <String>[];
      if (scopes.contains(MigrationScope.downloads)) {
        final dir = Directory(downloadPath);
        if (dir.existsSync()) {
          await for (final e in dir.list(recursive: true, followLinks: false)) {
            if (e is File && !_isMigrationPackage(e.path)) {
              downloads.add(e.path);
            }
          }
        }
      }
      final models = <String>[];
      if (scopes.contains(MigrationScope.models)) {
        for (final name in const ['ocr_models', 'ocr_packs', 'asr_packs']) {
          final dir = Directory(p.join(appSupportDirPath, name));
          if (dir.existsSync()) {
            await for (final e in dir.list(
              recursive: true,
              followLinks: false,
            )) {
              if (e is File) models.add(e.path);
            }
          }
        }
      }
      final assets = <String>[];
      if (scopes.contains(MigrationScope.assets)) {
        final bgDir = Directory(p.join(appSupportDirPath, 'background'));
        if (bgDir.existsSync()) {
          await for (final e in bgDir.list(recursive: true, followLinks: false)) {
            if (e is File) assets.add(e.path);
          }
        }
        final font = p.join(appSupportDirPath, 'customFont.otf');
        if (File(font).existsSync()) assets.add(font);
      }

      final total =
          boxNames.length +
          downloads.length +
          models.length +
          assets.length +
          1;
      var done = 0;
      void tick(String label) {
        done++;
        onProgress?.call((done / total).clamp(0.0, 0.99), label);
      }

      // 3. 流式写入 ZIP（临时文件）
      if (tmpFile.existsSync()) await tmpFile.delete();
      encoder = ZipFileEncoder()
        ..create(tmpFile.path, level: ZipFileEncoder.gzip);

      final entries = <MigrationEntry>[];

      Future<void> add(
        File file,
        String zipPath,
        String kind, {
        bool compress = true,
      }) async {
        if (!file.existsSync()) return;
        final size = await file.length();
        final crc = await _crc32Of(file);
        await encoder!.addFile(
          file,
          _zipPath(zipPath),
          compress ? ZipFileEncoder.gzip : ZipFileEncoder.store,
        );
        entries.add(
          MigrationEntry(
            path: _zipPath(zipPath),
            kind: kind,
            source: file.path,
            size: size,
            crc32: crc.toString(),
          ),
        );
        tick('已打包 ${p.basename(file.path)}');
      }

      for (final name in boxNames) {
        await add(File(hiveFiles[name]!), 'hive/$name.hive', 'hive');
      }
      for (final path in assets) {
        await add(
          File(path),
          'files/assets/${p.relative(path, from: appSupportDirPath)}',
          'asset',
        );
      }
      for (final path in models) {
        await add(
          File(path),
          'files/models/${p.relative(path, from: appSupportDirPath)}',
          'model',
          compress: false,
        );
      }
      for (final path in downloads) {
        await add(
          File(path),
          'files/download/${p.relative(path, from: downloadPath)}',
          'download',
          compress: false,
        );
      }

      // 4. 清单
      final manifest = MigrationManifest(
        appName: Constants.appName,
        appVersion: '${BuildConfig.versionName}+${BuildConfig.versionCode}',
        platform: DeviceUtils.platformName,
        exportedAt: DateTime.now().toIso8601String(),
        scopes: List.of(scopes),
        sourceDownloadPath: downloads.isEmpty ? null : downloadPath,
        entries: entries,
      );
      final manifestFile = File(p.join(tmpDirPath, 'migration_manifest.json'));
      await manifestFile.writeAsString(manifest.encode(), flush: true);
      await encoder.addFile(
        manifestFile,
        MigrationManifest.manifestName,
        ZipFileEncoder.gzip,
      );
      await manifestFile.delete();

      await encoder.close();
      encoder = null;
      debugPrint(
        '[Migration] after close: exists=${tmpFile.existsSync()} ' +
            'size=${tmpFile.existsSync() ? await tmpFile.length() : -1}',
      );

      // 5. 决定最终落点：
      //    默认留在临时目录（供调用方立刻复制到公共下载目录，避免双倍占用空间）；
      //    否则移动到应用下载目录。
      onProgress?.call(0.99, '正在保存…');
      // 交付物始终落在应用下载目录：临时目录里的文件在部分 ROM 上会出现
      // 「刚写完就不可见」的情况（2026-10-04 实测），不能作为最终交付位置。
      final dir = Directory(downloadPath);
      if (!dir.existsSync()) await dir.create(recursive: true);
      var target = p.join(dir.path, _defaultFileName());
      if (File(target).existsSync()) {
        var i = 1;
        while (File(p.join(dir.path, _defaultFileName(i))).existsSync()) {
          i++;
        }
        target = p.join(dir.path, _defaultFileName(i));
      }
      // 注意：临时目录与应用外置下载目录常处于不同文件系统，rename 会报
      // Cross-device link（2026-10-04 实测），必须用「复制 + 删除」。
      await tmpFile.copy(target);
      try {
        await tmpFile.delete();
      } catch (_) {}
      final String finalPath = target;
      final exported = File(finalPath);
      debugPrint(
        '[Migration] finalPath=$finalPath exists=${exported.existsSync()} '
        'size=${exported.existsSync() ? await exported.length() : -1}',
      );
      if (!exported.existsSync()) {
        throw StateError(
          '导出包在写出后即不可见（$finalPath），可能是系统清理了应用临时目录；'
          '请重试，或关闭「导出后自动复制到系统下载目录」改为写入应用目录。',
        );
      }
      onProgress?.call(1.0, '导出完成');

      return MigrationExportResult(
        path: finalPath,
        totalSize: manifest.totalSize,
        entries: entries.length,
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
      );
    } finally {
      debugPrint(
        '[Migration] export finally: tmpExists=${tmpFile.existsSync()} encoder=${encoder != null}',
      );
      // 导出不再关闭数据箱（见上方说明），故无需重开；失败路径同样保持可用。
      if (encoder != null) {
        try {
          await encoder.close();
        } catch (_) {}
      }
      try {
        if (tmpFile.existsSync()) await tmpFile.delete();
      } catch (_) {}
      debugPrint('[Migration] export end: _busy reset');
      _busy = false;
    }
  }

  /// 找出最近生成的迁移包（用于「复制到下载目录」补救入口，避免依赖会话内记录）：
  /// 依次扫描应用临时目录、应用下载目录，返回修改时间最新的一个。
  static Future<String?> findLatestPackage() async {
    File? latest;
    DateTime? latestTime;
    Future<void> scan(Directory dir, {int maxDepth = 2, int depth = 0}) async {
      if (!dir.existsSync() || depth > maxDepth) return;
      try {
        await for (final e in dir.list(followLinks: false)) {
          if (e is File) {
            if (!e.path.endsWith('.zip')) continue;
            if (!p.basename(e.path).startsWith('piliplus_migration')) continue;
            final st = e.statSync();
            final DateTime? previous = latestTime;
            if (previous == null || st.modified.isAfter(previous)) {
              latestTime = st.modified;
              latest = e;
            }
          } else if (e is Directory) {
            await scan(e, maxDepth: maxDepth, depth: depth + 1);
          }
        }
      } catch (_) {}
    }

    await scan(Directory(tmpDirPath));
    await scan(Directory(downloadPath), maxDepth: 1);
    return latest?.path;
  }

  /// 重启应用：导入替换了 Hive 文件后，必须重启才能重新打开数据箱。
  /// Android 经原生通道「拉起新实例 + 杀掉本进程」；桌面端直接退出。
  static Future<void> restartApp() async {
    if (Platform.isAndroid) {
      try {
        await const MethodChannel(
          'com.example.piliplus/app_control',
        ).invokeMethod('restartApp');
        return;
      } catch (_) {}
    }
    exit(0);
  }

  /// 把已导出的包复制到系统共享的下载目录（Windows 端为「下载」文件夹）
  static Future<SharedCopyResult?> copyToShared(
    String zipPath, {
    MigrateProgress? onProgress,
  }) async {
    onProgress?.call(0.2, '正在复制到下载目录…');
    final result = await SharedStorage.copyToDownloads(zipPath);
    onProgress?.call(1.0, result == null ? '复制失败' : '复制完成');
    return result;
  }

  static String _defaultFileName([int? index]) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}';
    final suffix = index == null ? '' : '_$index';
    return '${Constants.appName.toLowerCase()}_migration_$stamp$suffix.zip';
  }

  // ───────────────────────────── 导入：预检 ─────────────────────────────

  /// 解包到暂存目录并校验清单/哈希，返回可展示的预检结果（不修改任何现有数据）
  static Future<MigrationPreview> preview(
    String archivePath, {
    MigrateProgress? onProgress,
  }) async {
    final archiveFile = File(archivePath);
    if (!archiveFile.existsSync()) {
      throw const FormatException('文件不存在');
    }
    final staging = stagingDir;
    if (staging.existsSync()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    onProgress?.call(0.02, '正在读取安装包…');
    final input = InputFileStream(archiveFile.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final manifestFile = archive.findFile(MigrationManifest.manifestName);
      if (manifestFile == null) {
        throw const FormatException('不是有效的迁移包（缺少 manifest.json）');
      }
      final manifest = MigrationManifest.decode(manifestFile.readBytes()!);
      if (manifest.version != MigrationManifest.formatVersion) {
        throw FormatException(
          '迁移包版本不受支持（包=${manifest.version}，'
          '当前=${MigrationManifest.formatVersion}）',
        );
      }

      final warnings = <String>[];
      if (manifest.appName != Constants.appName) {
        warnings.add('该包来自 ${manifest.appName}，请确认来源可信');
      }
      if (manifest.platform != DeviceUtils.platformName) {
        warnings.add('该包导出平台为 ${manifest.platform}，跨平台迁移部分设置可能需要调整');
      }

      var done = 0;
      final total = manifest.entries.length;
      for (final entry in manifest.entries) {
        final file = archive.findFile(entry.path);
        if (file == null) {
          throw FormatException('迁移包缺少条目：${entry.path}');
        }
        final outPath = p.join(staging.path, _nativePath(entry.path));
        final out = File(outPath);
        await out.parent.create(recursive: true);
        final output = OutputFileStream(outPath);
        file.writeContent(output);
        await output.close();
        done++;
        onProgress?.call(
          (0.05 + 0.9 * done / (total == 0 ? 1 : total)).clamp(0.0, 0.96),
          '正在校验 ${p.basename(entry.path)}',
        );
      }

      // 哈希校验：Hive 与资产条目逐个校验，媒体条目体积过大只做尺寸核对
      for (final entry in manifest.entries) {
        final out = File(p.join(staging.path, _nativePath(entry.path)));
        if (!out.existsSync()) throw FormatException('解包缺失：${entry.path}');
        if (entry.kind == 'download' || entry.kind == 'model') {
          if (await out.length() != entry.size) {
            throw FormatException('文件不完整：${p.basename(entry.path)}');
          }
          continue;
        }
        final crc = await _crc32Of(out);
        if (crc != int.parse(entry.crc32)) {
          throw FormatException('文件校验失败：${p.basename(entry.path)}');
        }
      }

      final preview = MigrationPreview(
        manifest: manifest,
        archivePath: archivePath,
        stagingDir: staging.path,
        hasHive: manifest.byKind('hive').isNotEmpty,
        hasAssets: manifest.byKind('asset').isNotEmpty,
        hasModels: manifest.byKind('model').isNotEmpty,
        hasDownloads: manifest.byKind('download').isNotEmpty,
        fileCount: manifest.entries.length,
        totalSize: manifest.totalSize,
        warnings: warnings,
      );
      onProgress?.call(1.0, '校验完成');
      return preview;
    } finally {
      try {
        await input.close();
      } catch (_) {}
    }
  }

  static Future<void> discardStaging() async {
    final dir = stagingDir;
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  // ───────────────────────────── 导入：落盘 ─────────────────────────────

  /// 执行导入：备份现有 Hive → 替换 → 还原资产/模型/缓存视频 → 改写条目路径
  static Future<MigrationApplyResult> apply(
    MigrationPreview preview, {
    required String currentDownloadPath,
    MigrateProgress? onProgress,
  }) async {
    if (_busy) throw StateError('已有迁移任务在进行中');
    _busy = true;
    debugPrint(
      '[Migration] apply start: hive=${preview.hasHive} assets=${preview.hasAssets} '
      'models=${preview.hasModels} downloads=${preview.hasDownloads} '
      'staging=${preview.stagingDir}',
    );
    final staging = Directory(preview.stagingDir);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    Directory? backupDir;
    try {
      // 1. 备份现有 Hive
      if (preview.hasHive) {
        onProgress?.call(0.1, '正在备份现有数据…');
        await GStorage.compact();
        await GStorage.closeForMigration();
        backupDir = Directory('${GStorage.hiveDirPath}_backup_$stamp');
        await _copyDir(Directory(GStorage.hiveDirPath), backupDir);
      }

      // 2. 替换 Hive（替换前先确认暂存区真的有数据箱文件，否则宁可不动旧数据）
      if (preview.hasHive) {
        final srcHive = Directory(p.join(staging.path, 'hive'));
        final staged = srcHive.existsSync()
            ? srcHive
                  .listSync()
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.hive') && f.lengthSync() >= 0)
                  .toList()
            : const <File>[];
        if (staged.isEmpty) {
          throw StateError('暂存区没有可用的数据箱文件，已中止导入以免清空现有数据');
        }
        debugPrint('[Migration] apply: staged hive files = ${staged.length}');
        onProgress?.call(0.3, '正在写入数据…');
        final hiveDir = Directory(GStorage.hiveDirPath);
        if (hiveDir.existsSync()) await hiveDir.delete(recursive: true);
        await hiveDir.create(recursive: true);
        final src = Directory(p.join(staging.path, 'hive'));
        if (src.existsSync()) await _copyDir(src, hiveDir);
      }

      // 3. 资产：包内已按真实相对路径存放（background/xxx.jpg、customFont.otf），
      //    整棵复制回 appSupportDir 即可；旧版包把图片平铺在 assets 根，做一次兼容搬移。
      if (preview.hasAssets) {
        onProgress?.call(0.45, '正在还原背景与字体…');
        final src = Directory(p.join(staging.path, 'files', 'assets'));
        if (src.existsSync()) {
          const legacyNames = ['globalBg.jpg', 'homeBg.png', 'mineBg.jpg'];
          await for (final e in src.list(recursive: true, followLinks: false)) {
            if (e is! File) continue;
            final rel = p.relative(e.path, from: src.path);
            final isLegacyFlat =
                !rel.contains(p.separator) && legacyNames.contains(rel);
            final target = p.join(
              appSupportDirPath,
              isLegacyFlat ? p.join('background', rel) : rel,
            );
            await Directory(p.dirname(target)).create(recursive: true);
            await e.copy(target);
          }
        }
      }

      // 4. 模型包
      if (preview.hasModels) {
        onProgress?.call(0.6, '正在还原模型包…');
        final src = Directory(p.join(staging.path, 'files', 'models'));
        if (src.existsSync()) {
          await _copyDir(src, Directory(appSupportDirPath));
        }
      }

      // 5. 缓存视频（落到当前设备的下载目录，并改写条目内绝对路径）
      if (preview.hasDownloads) {
        onProgress?.call(0.75, '正在还原缓存视频…');
        final src = Directory(p.join(staging.path, 'files', 'download'));
        final target = Directory(currentDownloadPath);
        if (src.existsSync()) {
          await target.create(recursive: true);
          await _copyDir(src, target);
        }
        final source = preview.manifest.sourceDownloadPath;
        if (source != null &&
            source.isNotEmpty &&
            source != currentDownloadPath) {
          await _rewriteDownloadEntryPaths(target, source, currentDownloadPath);
        }
      }

      debugPrint('[Migration] apply: files placed, finishing');
      onProgress?.call(0.98, '正在清理…');
      await discardStaging();
      onProgress?.call(1.0, '导入完成');
      return MigrationApplyResult(
        success: true,
        backupDir: backupDir?.path,
        message: '导入完成。请完全退出应用后重新打开，以确保全部设置生效',
      );
    } catch (e) {
      // 失败回滚：把备份目录还原回去
      if (backupDir != null && backupDir.existsSync()) {
        try {
          final hiveDir = Directory(GStorage.hiveDirPath);
          if (hiveDir.existsSync()) await hiveDir.delete(recursive: true);
          await _copyDir(backupDir, hiveDir);
        } catch (_) {}
      }
      return MigrationApplyResult(
        success: false,
        backupDir: backupDir?.path,
        message: '导入失败：$e',
      );
    } finally {
      // 同上：箱已关闭，由界面提示重启，不做原地重开
      _busy = false;
    }
  }

  /// 导入后重建下载列表（下载目录被替换过时调用）
  static void refreshDownloadList() {
    if (Get.isRegistered<DownloadService>()) {
      Get.find<DownloadService>().initDownloadList();
    }
  }

  // ───────────────────────────── 工具 ─────────────────────────────

  /// 改写 entry.json 中持久化的源设备绝对路径，避免导入端指向不存在的目录
  static Future<void> _rewriteDownloadEntryPaths(
    Directory downloadDir,
    String sourcePrefix,
    String targetPrefix,
  ) async {
    final normalizedSource = _zipPath(sourcePrefix);
    await for (final entity in downloadDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith('entry.json')) continue;
      try {
        final content = await entity.readAsString();
        final json = jsonDecode(content) as Map;
        var changed = false;
        for (final key in const ['page_dir_path', 'entry_dir_path']) {
          final value = json[key];
          if (value is! String || value.isEmpty) continue;
          if (_zipPath(value).startsWith(normalizedSource)) {
            final rel = _zipPath(value).substring(normalizedSource.length);
            json[key] = _nativePath('$targetPrefix$rel');
            changed = true;
          }
        }
        if (changed) {
          await entity.writeAsString(jsonEncode(json), flush: true);
        }
      } catch (_) {
        // 单个条目损坏不影响整体导入
      }
    }
  }

  static Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: from.path);
      final target = p.join(to.path, rel);
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        if (entity.path.endsWith('.lock')) continue;
        await File(target).parent.create(recursive: true);
        await entity.copy(target);
      }
    }
  }

  static Future<int> _crc32Of(File file) async {
    var crc = 0;
    await for (final chunk in file.openRead()) {
      crc = getCrc32(chunk, crc);
    }
    return crc;
  }
}
