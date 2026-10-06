import 'dart:convert';

/// 数据迁移包的作用范围（可多选组合）
abstract final class MigrationScope {
  /// 轻量：仅「设置」与「视频设置」两箱
  static const light = 'light';

  /// 标准：全部 Hive 箱（含登录信息与回复草稿）
  static const standard = 'standard';

  /// 附加：用户资产（背景图、自定义字体）
  static const assets = 'assets';

  /// 附加：OCR / ASR 模型包（体积较大）
  static const models = 'models';

  /// 附加：已缓存视频（download 目录，体积最大）
  static const downloads = 'downloads';

  static const all = [light, standard, assets, models, downloads];

  static String label(String scope) => switch (scope) {
    light => '设置',
    standard => '全部数据（含登录信息）',
    assets => '背景与字体',
    models => '识别模型包',
    downloads => '已缓存视频',
    _ => scope,
  };

  static String desc(String scope) => switch (scope) {
    light => '播放、界面、弹幕等全部设置项，体积最小',
    standard => '设置 + 登录信息 + 搜索历史 + 观看进度 + 回复草稿',
    assets => '自定义背景图与自定义字体',
    models => 'OCR 检测/识别模型与 ASR 语音识别模型（数十至数百 MB）',
    downloads => '离线缓存/下载的视频、弹幕与封面（体积取决于缓存量）',
    _ => '',
  };
}

/// 迁移包内的单个条目
class MigrationEntry {
  /// 包内相对路径，例如 hive/setting.hive、files/download/xxx/entry.json
  final String path;

  /// 逻辑分类：hive / asset / model / download
  final String kind;

  /// 原始绝对路径（仅在导出端有意义，用于导入时改写路径）
  final String source;

  final int size;

  /// CRC32 校验值（十进制字符串，避免 JSON 精度问题）
  final String crc32;

  MigrationEntry({
    required this.path,
    required this.kind,
    required this.source,
    required this.size,
    required this.crc32,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'kind': kind,
    'source': source,
    'size': size,
    'crc32': crc32,
  };

  factory MigrationEntry.fromJson(Map json) => MigrationEntry(
    path: json['path'] as String,
    kind: (json['kind'] as String?) ?? 'unknown',
    source: (json['source'] as String?) ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    crc32: (json['crc32'] as String?) ?? '0',
  );
}

/// 迁移包清单（manifest.json）
class MigrationManifest {
  static const formatVersion = 1;
  static const manifestName = 'manifest.json';

  final int? version;
  final String appName;
  final String appVersion;
  final String platform;
  final String exportedAt;
  final List<String> scopes;
  final String? sourceDownloadPath;
  final List<MigrationEntry> entries;

  MigrationManifest({
    this.version,
    required this.appName,
    required this.appVersion,
    required this.platform,
    required this.exportedAt,
    required this.scopes,
    this.sourceDownloadPath,
    required this.entries,
  });

  int get totalSize => entries.fold(0, (sum, e) => sum + e.size);

  Iterable<MigrationEntry> byKind(String kind) =>
      entries.where((e) => e.kind == kind);

  bool has(String scope) => scopes.contains(scope);

  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'appName': appName,
    'appVersion': appVersion,
    'platform': platform,
    'exportedAt': exportedAt,
    'scopes': scopes,
    'sourceDownloadPath': sourceDownloadPath,
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory MigrationManifest.fromJson(Map json) => MigrationManifest(
    version: (json['version'] as num?)?.toInt(),
    appName: (json['appName'] as String?) ?? '',
    appVersion: (json['appVersion'] as String?) ?? '',
    platform: (json['platform'] as String?) ?? '',
    exportedAt: (json['exportedAt'] as String?) ?? '',
    scopes: ((json['scopes'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    sourceDownloadPath: json['sourceDownloadPath'] as String?,
    entries: ((json['entries'] as List?) ?? const [])
        .map((e) => MigrationEntry.fromJson(e as Map))
        .toList(),
  );

  static MigrationManifest decode(List<int> bytes) =>
      MigrationManifest.fromJson(jsonDecode(utf8.decode(bytes)) as Map);
}
