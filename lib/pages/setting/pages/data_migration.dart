import 'dart:async';

import 'package:path/path.dart' as p;
import 'dart:io';

import 'package:PiliPlus/common/widgets/flutter/list_tile.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/models/migration/migration_manifest.dart';
import 'package:PiliPlus/services/migration/migration_service.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:material_ui/material_ui.dart' hide ListTile;
import 'package:PiliPlus/utils/platform_utils.dart';

/// 数据迁移：把应用数据导出为单个离线包，并可导入还原
class DataMigrationPage extends StatefulWidget {
  const DataMigrationPage({super.key});

  @override
  State<DataMigrationPage> createState() => _DataMigrationPageState();
}

class _DataMigrationPageState extends State<DataMigrationPage> {
  /// 默认勾选「标准」，即整机搬迁的常用组合
  final Set<String> _scopes = {MigrationScope.standard};

  int? _estimate;
  bool _estimating = false;
  bool _busy = false;

  MigrationPreview? _preview;
  String? _previewError;

  /// 上一次导出的包（用于「复制到下载目录」补救）
  String? _lastExportPath;

  /// 导出到系统共享下载目录（用户可在文件管理器/MTP 中直接取得）。
  /// 注意：默认值必须是「移动端即开启」，且不能依赖已有键——旧版本可能从未写入该键，
  /// 用户看到的开关状态与实际值不一致时会出现「明明开着却仍落私有目录」（2026-10-04 踩到）。
  late bool _toShared =
      GStorage.setting.get(
        SettingBoxKey.migrationToShared,
        defaultValue: true,
      ) ||
      PlatformUtils.isMobile;

  bool _copying = false;

  /// 文件选择器是否正在打开（防止重复触发 already_active）
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _refreshEstimate();
  }

  bool get _isLight => _scopes.contains(MigrationScope.light);

  bool get _isStandard => _scopes.contains(MigrationScope.standard);

  Future<void> _refreshEstimate() async {
    if (_scopes.isEmpty) {
      setState(() => _estimate = null);
      return;
    }
    setState(() => _estimating = true);
    try {
      final size = await MigrationService.estimateSize(_scopes.toList());
      if (mounted) setState(() => _estimate = size);
    } finally {
      if (mounted) setState(() => _estimating = false);
    }
  }

  void _toggle(String scope, bool? value) {
    setState(() {
      if (value ?? false) {
        _scopes.add(scope);
      } else {
        _scopes.remove(scope);
      }
      // 「轻量」与「标准」互斥：两者都描述 Hive 箱的覆盖面
      if (scope == MigrationScope.light && _isLight) {
        _scopes.remove(MigrationScope.standard);
      } else if (scope == MigrationScope.standard && _isStandard) {
        _scopes.remove(MigrationScope.light);
      }
    });
    _refreshEstimate();
  }

  // ───────────────────────────── 导出 ─────────────────────────────

  Future<void> _export() async {
    if (_scopes.isEmpty) {
      SmartDialog.showToast('请至少选择一项导出内容');
      return;
    }
    final scopes = _scopes.toList();
    final withDownloads = scopes.contains(MigrationScope.downloads);
    debugPrint('[Migration] export start: toShared=$_toShared scopes=$scopes');
    final ok = await _confirm(
      title: '导出数据包',
      content:
          '将导出：${scopes.map(MigrationScope.label).join('、')}\n'
          '预计体积：${_estimate == null ? '计算中' : '${CacheManager.formatSize(_estimate!)} (${_estimate!} 字节)'}\n'
          '${withDownloads ? '包含已缓存视频，体积较大且耗时较长，请勿中途退出。\n' : ''}'
          '导出包内含登录凭据，请勿公开分享。',
      confirmText: '开始导出',
    );
    if (ok != true) return;

    await _runWithProgress(
      title: '正在导出',
      task: (report) => MigrationService.export(
        scopes: scopes,
        toSharedStorage: _toShared,
        onProgress: report,
      ),
      onSuccess: (result) async {
        _lastExportPath = result.path;
        String? sharedPath;
        if (_toShared) {
          final shared = await MigrationService.copyToShared(result.path);
          debugPrint('[Migration] copyToShared -> ${shared?.displayPath} (method=${shared?.method})');
          sharedPath = shared?.displayPath;
          // 复制完成后再删掉临时包，避免占用双份空间
          if (sharedPath != null) {
            try {
              await File(result.path).delete();
              _lastExportPath = null;
            } catch (_) {}
          }
        }
        SmartDialog.showToast('导出成功');
        _showResultDialog(
          title: '导出完成',
          lines: [
            if (sharedPath != null)
              '位置：$sharedPath'
            else
              '文件：${result.path}',
            '条目：${result.entries}',
            '体积：${CacheManager.formatSize(result.totalSize)}',
            '耗时：${(result.elapsedMs / 1000).toStringAsFixed(1)} 秒',
            if (sharedPath == null)
              '提示：当前落在应用私有目录，PC 与文件管理器都读不到；建议打开「导出到下载目录」后重新导出。',
            '为释放数据文件占用，请在本页操作完成后重启应用。',
          ],
        );
      },
      onError: (e) {
        _lastExportPath = null;
        SmartDialog.showToast('导出失败：$e');
      },
    );
  }

  /// 把最近导出的包复制到系统共享的下载目录（补救私有目录取不出的问题）。
  /// 不依赖会话内记录：没有记录时先扫描磁盘找最新的迁移包。
  Future<void> _copyToDownloads() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      final path = _lastExportPath ?? await MigrationService.findLatestPackage();
      if (path == null) {
        SmartDialog.showToast('没有找到可搬运的迁移包');
        return;
      }
      _lastExportPath = path;
      final result = await MigrationService.copyToShared(path);
      if (result == null) {
        SmartDialog.showToast('复制失败，请检查存储空间');
        return;
      }
      try {
        await File(path).delete();
        _lastExportPath = null;
      } catch (_) {}
      _showResultDialog(
        title: '已复制到下载目录',
        lines: [
          '位置：${result.displayPath}',
          '体积：${CacheManager.formatSize(result.size)}',
          if (result.method != null) '写入方式：${result.method}',
          '现在可用文件管理器、快传或连接电脑（MTP）取出该文件。',
        ],
      );
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  // ───────────────────────────── 导入 ─────────────────────────────

  /// 选择数据包 → 解包校验 → 展示将会覆盖的内容（不修改任何现有数据）
  Future<void> _pickArchive() async {
    // 注意：file_picker 在 Android 上会把所选文件**整体复制到应用缓存**后才返回，
    // 选大包（GB 级）时会静默等待数十秒——这里必须先给出可见提示，否则用户以为没反应。
    SmartDialog.showLoading(
      msg: '正在读取所选文件…\n大文件需要先复制到应用缓存，请稍候',
      maskColor: Colors.black38,
      clickMaskDismiss: false,
    );
    if (_picking) {
      SmartDialog.showToast('文件选择器已打开，请先完成选择');
      return;
    }
    setState(() => _picking = true);
    final PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
    } on PlatformException catch (e) {
      SmartDialog.showToast('打开文件选择器失败：${e.code}');
      return;
    } finally {
      unawaited(SmartDialog.dismiss<void>());
      if (mounted) setState(() => _picking = false);
    }
    if (picked == null) return;

    // ⚠️ 关键：SAF 返回的可能是 content:// 形式，此时 PlatformFile.path 为 null
    // （旧代码用 path! 直接崩溃：Null check operator used on a null value，
    // 表现为「选完文件什么都没发生」，2026-10-04 实测）。这里统一落地成本地路径。
    final String archivePath;
    final directPath = picked.path;
    if (directPath != null && directPath.isNotEmpty && File(directPath).existsSync()) {
      archivePath = directPath;
    } else {
      try {
        archivePath = await _materialize(picked);
      } catch (e) {
        setState(() => _previewError = '读取所选文件失败：$e');
        SmartDialog.showToast('读取所选文件失败：$e');
        return;
      }
    }
    setState(() {
      _preview = null;
      _previewError = null;
    });
    await _runWithProgress(
      title: '正在校验安装包',
      task: (report) => MigrationService.preview(archivePath, onProgress: report),
      onSuccess: (preview) async {
        setState(() => _preview = preview);
        // 校验通过后主动询问并可直接导入：旧版只把「导入并覆盖」放在页面下方，
        // 用户校验完不往下滚就会以为「什么都没导入」（2026-10-04 反馈）。
        await _promptImport(preview);
      },
      onError: (e) {
        setState(() => _previewError = '$e');
      },
    );
  }

  /// 把 SAF 选中的文件（可能是 content:// 形式、没有真实路径）流式复制到应用缓存，
  /// 返回可用于解包的本地路径。流式复制避免 GB 级文件占满内存。
  Future<String> _materialize(PlatformFile file) async {
    final dst = File(
      p.join(
        tmpDirPath,
        'migration_import_${DateTime.now().millisecondsSinceEpoch}.zip',
      ),
    );
    final sink = dst.openWrite();
    try {
      await for (final chunk in file.xFile.openRead()) {
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return dst.path;
  }

  /// 校验通过后的确认导入
  Future<void> _promptImport(MigrationPreview preview) async {
    final ok = await _confirm(
      title: '校验通过',
      content:
          '将导入以下内容：\n• ${preview.summary.join('\n• ')}\n\n'
          '来源：${preview.manifest.appName} ${preview.manifest.appVersion}'
          '（${preview.manifest.platform}）\n'
          '${preview.hasHive ? '' : '⚠ 该包不含设置/登录数据，导入后应用设置不会变化。\n'}'
          '导入前会自动备份现有数据，导入后需重启应用生效。',
      confirmText: '立即导入',
      danger: true,
    );
    if (ok == true) {
      await _apply(askConfirm: false);
    }
  }

  /// 落盘导入
  Future<void> _apply({bool askConfirm = true}) async {
    final preview = _preview;
    if (preview == null) return;
    if (askConfirm && preview.hasHive) {
      final ok = await _confirm(
        title: '导入数据',
        content:
            '将覆盖以下内容：\n• ${preview.summary.join('\n• ')}\n\n'
            '导入前会自动备份现有数据，导入后需重启应用生效。',
        confirmText: '覆盖并导入',
        danger: true,
      );
      if (ok != true) return;
    }
    await _runWithProgress(
      title: '正在导入',
      task: (report) => MigrationService.apply(
        preview,
        currentDownloadPath: downloadPath,
        onProgress: report,
      ),
      onSuccess: (result) {
        if (!result.success) {
          SmartDialog.showToast(result.message);
          return;
        }
        if (preview.hasDownloads) MigrationService.refreshDownloadList();
        setState(() => _preview = null);
        if (preview.hasHive) {
          // 数据箱已被替换：不重启的话，应用仍用内存里的旧设置，看起来「没导进去」
          _showRestartDialog(result);
        } else {
          _showResultDialog(
            title: '导入完成',
            lines: [result.message, '该包不含设置数据，仅恢复了所选内容。'],
          );
        }
      },
      onError: (e) {
        SmartDialog.showToast('导入失败：$e');
      },
    );
  }

  // ───────────────────────────── 通用 ─────────────────────────────

  Future<T?> _runWithProgress<T>({
    required String title,
    required Future<T> Function(MigrateProgress report) task,
    void Function(T result)? onSuccess,
    void Function(Object error)? onError,
  }) async {
    if (_busy) {
      SmartDialog.showToast('已有迁移任务在进行中');
      return null;
    }
    setState(() => _busy = true);
    final progress = ValueNotifier<(double, String)>((0, '准备中…'));
    SmartDialog.show(
      builder: (_) => ValueListenableBuilder<(double, String)>(
        valueListenable: progress,
        builder: (_, data, _) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: data.$1),
              const SizedBox(height: 12),
              Text(
                data.$2,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      ),
      clickMaskDismiss: false,
      maskColor: Colors.black38,
    );
    try {
      final result = await task((v, label) => progress.value = (v, label));
      onSuccess?.call(result);
      return result;
    } catch (e) {
      if (onError != null) {
        onError(e);
      } else {
        SmartDialog.showToast('$e');
      }
      return null;
    } finally {
      progress.dispose();
      unawaited(SmartDialog.dismiss<void>());
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String content,
    required String confirmText,
    bool danger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        final colorScheme = ColorScheme.of(context);
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(content)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('取消', style: TextStyle(color: colorScheme.outline)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                confirmText,
                style: TextStyle(
                  color: danger ? colorScheme.error : colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 导入替换数据箱后，引导用户立刻重启（否则设置看起来没生效）
  void _showRestartDialog(MigrationApplyResult result) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('导入完成'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('设置与登录信息已写入，需重启应用后才会生效。'),
              const SizedBox(height: 8),
              if (result.backupDir != null)
                SelectableText(
                  '原数据已备份至：${result.backupDir}',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后手动重启'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await MigrationService.restartApp();
            },
            child: const Text('立即重启'),
          ),
        ],
      ),
    );
  }

  void _showResultDialog({required String title, required List<String> lines}) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SelectableText(
                    line,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────── UI ─────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return SimpleScaffold(
      appBar: AppBar(title: const Text('数据迁移')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _sectionTitle('导出内容', colorScheme),
          for (final scope in MigrationScope.all)
            CheckboxListTile(
              value: _scopes.contains(scope),
              onChanged: _busy ? null : (v) => _toggle(scope, v),
              title: Text(
                MigrationScope.label(scope),
                style: const TextStyle(fontSize: 15),
              ),
              subtitle: Text(
                MigrationScope.desc(scope),
                style: const TextStyle(fontSize: 12),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
          ListTile(
            leading: const Icon(Icons.folder_zip_outlined),
            title: const Text('导出数据包', style: TextStyle(fontSize: 15)),
            subtitle: Text(
              _estimating
                  ? '正在估算体积…'
                  : _estimate == null
                  ? '未选择任何内容'
                  : '预计体积 ${CacheManager.formatSize(_estimate!)}'
                        '${_scopes.contains(MigrationScope.downloads) || _scopes.contains(MigrationScope.models) ? '（体积较大）' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_busy && _scopes.isNotEmpty,
            onTap: _busy ? null : _export,
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('导出后自动复制到系统下载目录', style: TextStyle(fontSize: 15)),
            subtitle: const Text(
              '写入系统「下载」目录，文件管理器与电脑 MTP 可直接取出；关闭则留在应用私有目录',
              style: TextStyle(fontSize: 12),
            ),
            trailing: Switch(
              value: _toShared,
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() => _toShared = v);
                      GStorage.setting.put(SettingBoxKey.migrationToShared, v);
                    },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.content_copy_outlined),
            title: Text(
              _copying ? '正在复制…' : '把上次导出的包复制到下载目录',
              style: const TextStyle(fontSize: 15),
            ),
            subtitle: const Text(
              '自动查找最近生成的迁移包并复制到系统下载目录（Download/PiliPlus），便于取出',
              style: TextStyle(fontSize: 12),
            ),
            enabled: !_busy && !_copying,
            onTap: _busy || _copying ? null : _copyToDownloads,
          ),
          const Divider(height: 1),
          _sectionTitle('导入数据包', colorScheme),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('选择数据包并校验', style: TextStyle(fontSize: 15)),
            subtitle: const Text(
              '导入前会先解包校验并展示将覆盖的内容',
              style: TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_busy,
            onTap: _busy ? null : _pickArchive,
          ),
          if (_previewError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '校验失败：$_previewError',
                style: TextStyle(color: colorScheme.error, fontSize: 13),
              ),
            ),
          if (_preview case final preview?) ...[
            _previewCard(preview, colorScheme),
            ListTile(
              leading: Icon(
                Icons.restore_outlined,
                color: colorScheme.error,
              ),
              title: Text(
                '导入并覆盖',
                style: TextStyle(fontSize: 15, color: colorScheme.error),
              ),
              subtitle: const Text(
                '覆盖前自动备份现有数据',
                style: TextStyle(fontSize: 12),
              ),
              enabled: !_busy,
              onTap: _busy ? null : _apply,
            ),
          ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '说明：\n'
              '• 迁移包为单个 ZIP 文件，内含 Hive 数据与可选资产、模型、缓存视频；\n'
              '• 视频与模型不压缩存储，避免无意义的耗时；\n'
              '• 包内包含登录凭据（明文），请勿公开分享；\n'
              '• 导入完成后建议完全重启应用。',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.outline,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, ColorScheme colorScheme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: colorScheme.primary,
      ),
    ),
  );

  Widget _previewCard(
    MigrationPreview preview,
    ColorScheme colorScheme,
  ) => Card(
    margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '包信息',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '来自 ${preview.manifest.appName} ${preview.manifest.appVersion}'
            '（${preview.manifest.platform}）\n'
            '条目 ${preview.fileCount} 个，共 ${CacheManager.formatSize(preview.totalSize)}',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          Text(
            '将导入',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          for (final line in preview.summary)
            Text('• $line', style: const TextStyle(fontSize: 13)),
          if (preview.warnings.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final warning in preview.warnings)
              Text(
                '⚠ $warning',
                style: TextStyle(fontSize: 12, color: colorScheme.error),
              ),
          ],
        ],
      ),
    ),
  );
}
