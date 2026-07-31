import 'dart:io';
import 'dart:typed_data';

/// 简易 TTF/OTF/TTC 字体名称解析器
/// 从字体文件的 name 表中提取 Family Name，用于界面友好显示。
abstract final class FontNameParser {
  /// 解析字体文件中的 Family Name。
  /// 失败时返回 null，调用方可回退到文件名。
  static String? parseFamilyName(File file) {
    try {
      final bytes = file.readAsBytesSync();
      if (bytes.length < 12) return null;
      final data = ByteData.sublistView(bytes);
      final sfntVersion = data.getUint32(0);

      // TTC (TrueType Collection)：跳转到第一个字体的 offset table
      int offsetTableOffset = 0;
      if (sfntVersion == 0x74746366 /* 'ttcf' */) {
        if (bytes.length < 16) return null;
        final numFonts = data.getUint32(12);
        if (numFonts < 1 || bytes.length < 16) return null;
        offsetTableOffset = data.getUint32(16);
      }

      if (offsetTableOffset + 12 > bytes.length) return null;
      final numTables = data.getUint16(offsetTableOffset + 4);
      if (numTables == 0) return null;

      // 遍历 table records 找 'name' 表
      int? nameOffset;
      int? nameLength;
      for (var i = 0; i < numTables; i++) {
        final recordOffset = offsetTableOffset + 12 + i * 16;
        if (recordOffset + 16 > bytes.length) break;
        final tag = String.fromCharCodes(
          bytes.sublist(recordOffset, recordOffset + 4),
        );
        if (tag == 'name') {
          nameOffset = data.getUint32(recordOffset + 8);
          nameLength = data.getUint32(recordOffset + 12);
          break;
        }
      }

      if (nameOffset == null || nameLength == null) return null;
      if (nameOffset + nameLength > bytes.length) return null;

      final count = data.getUint16(nameOffset + 2);
      final stringOffset = data.getUint16(nameOffset + 4);
      if (count == 0) return null;

      // 只解析 Unicode 条目（platformID 0=Unicode / 3=Windows），避免 MacRoman 中文乱码。
      // 优先 nameID=16 (typographic family)，其次 nameID=1 (family)。
      String? fallback;
      for (var i = 0; i < count; i++) {
        final record = nameOffset + 6 + i * 12;
        if (record + 12 > bytes.length) break;
        final platformID = data.getUint16(record);
        if (platformID != 0 && platformID != 3) continue;
        final nameID = data.getUint16(record + 6);
        if (nameID != 1 && nameID != 16) continue;
        final length = data.getUint16(record + 8);
        final offset = data.getUint16(record + 10);
        final strStart = nameOffset + stringOffset + offset;
        if (strStart + length > bytes.length) continue;

        final decoded = _decodeUtf16BE(bytes, strStart, length);
        if (decoded == null || decoded.isEmpty) continue;
        if (!_isValidName(decoded)) continue;
        if (nameID == 16) return decoded;
        fallback ??= decoded;
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  /// UTF-16BE 解码
  static String? _decodeUtf16BE(Uint8List bytes, int start, int length) {
    try {
      if (length < 2 || length.isOdd) return null;
      final codes = Uint16List(length ~/ 2);
      for (var i = 0; i < codes.length; i++) {
        codes[i] = (bytes[start + i * 2] << 8) | bytes[start + i * 2 + 1];
      }
      return String.fromCharCodes(codes).replaceAll('\u0000', '').trim();
    } catch (_) {
      return null;
    }
  }

  /// 过滤明显异常的字符（控制字符、替换符等）
  static bool _isValidName(String name) {
    for (final unit in name.codeUnits) {
      // 0x00-0x1F 控制字符、0xFFFD 替换符、0x0000
      if (unit < 0x20 || unit == 0xFFFD) return false;
    }
    return true;
  }
}
