import 'dart:convert' show utf8;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/storage_utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

typedef SubSeg = ({Duration start, Duration end, String text});

/// 字幕工作台：展示 OCR/ASR 整段识别结果，勾选整合并导出 SRT
class SubtitleWorkbenchPage extends StatefulWidget {
  final PlPlayerController controller;
  const SubtitleWorkbenchPage({super.key, required this.controller});

  @override
  State<SubtitleWorkbenchPage> createState() => _SubtitleWorkbenchPageState();
}

class _SubtitleWorkbenchPageState extends State<SubtitleWorkbenchPage> {
  late final PlPlayerController c = widget.controller;
  final Set<int> _ocrSel = {};
  final Set<int> _asrSel = {};
  bool _busy = false;
  bool _ocrBusy = false;
  bool _asrBusy = false;
  final ScrollController _logScroll = ScrollController();

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _scrollLogToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.animateTo(
          _logScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('字幕工作台'),
        actions: [
          IconButton(
            tooltip: '导出 SRT',
            icon: const Icon(Icons.save_alt),
            onPressed: _busy ? null : _export,
          ),
        ],
      ),
      body: Column(
        children: [
          // 操作栏：触发识别
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _ocrBusy ? null : _runOcr,
                    icon: _ocrBusy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.image_search, size: 18),
                    label: Text(_ocrBusy ? 'OCR 识别中…' : '整段识别画面文字(OCR)'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _asrBusy ? null : _runAsr,
                    icon: _asrBusy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.record_voice_over, size: 18),
                    label: Text(_asrBusy ? 'ASR 识别中…' : '整段识别语音(ASR)'),
                  ),
                ),
              ],
            ),
          ),
          // 识别进度标识
          Obx(() {
            final ocrP = c.ocrFullProgress.value;
            final asrP = c.asrFullProgress.value;
            final line = [if (ocrP.isNotEmpty) 'OCR: $ocrP', if (asrP.isNotEmpty) 'ASR: $asrP'].join('\n');
            if (line.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.blueGrey.shade700,
                  ),
                ),
              ),
            );
          }),
          // 状态提示
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '勾选要保留的字幕段，可同时选 OCR 与 ASR 结果整合；导出为 SRT 字幕文件。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  TabBar(
                    tabs: [
                      Tab(text: 'OCR 画面文字 (${c.ocrFullSegments.length})'),
                      Tab(text: 'ASR 语音 (${c.asrSegments.length})'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _segList(c.ocrFullSegments, _ocrSel, isOcr: true),
                        _segList(c.asrSegments, _asrSel, isOcr: false),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 识别日志区（shell 风格滚动，毛玻璃背景）
          Container(
            height: 180,
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey.shade800)),
            ),
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.2),
                  child: Obx(
                    () {
                      final logs = c.workbenchLogs;
                      if (logs.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text(
                            '识别日志将显示在这里',
                            style: TextStyle(color: Colors.grey, fontSize: 11),
                          ),
                        );
                      }
                      _scrollLogToEnd();
                      return ListView.builder(
                        controller: _logScroll,
                        padding: const EdgeInsets.all(6),
                        itemCount: logs.length,
                        itemBuilder: (context, i) => Text(
                          logs[i],
                          style: const TextStyle(
                            color: Color(0xFF9CDCFE),
                            fontSize: 11,
                            height: 1.4,
                            fontFamily: 'monospace',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _segList(List<SubSeg> segs, Set<int> sel, {required bool isOcr}) {
    if (segs.isEmpty) {
      return Center(
        child: Text(
          '暂无${isOcr ? ' OCR' : ' ASR'}识别结果\n点击上方按钮开始整段识别',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      itemCount: segs.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Row(
            children: [
              const SizedBox(width: 12),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (sel.length == segs.length) {
                      sel.clear();
                    } else {
                      sel
                        ..clear()
                        ..addAll(List.generate(segs.length, (k) => k));
                    }
                  });
                },
                child: Text(sel.length == segs.length ? '取消全选' : '全选'),
              ),
              Text(
                '已选 ${sel.length}/${segs.length}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          );
        }
        final idx = i - 1;
        final seg = segs[idx];
        return CheckboxListTile(
          value: sel.contains(idx),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (v) {
            setState(() {
              if (v == true) {
                sel.add(idx);
              } else {
                sel.remove(idx);
              }
            });
          },
          title: Text(
            seg.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            '${_fmt(seg.start)} - ${_fmt(seg.end)}',
            style: const TextStyle(fontSize: 11),
          ),
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _runOcr() async {
    setState(() => _ocrBusy = true);
    try {
      await c.runFullOcr();
    } finally {
      if (mounted) setState(() => _ocrBusy = false);
    }
  }

  Future<void> _runAsr() async {
    setState(() => _asrBusy = true);
    try {
      await c.runFullAsr();
    } finally {
      if (mounted) setState(() => _asrBusy = false);
    }
  }

  Future<void> _export() async {
    final merged = <SubSeg>[
      for (final i in _ocrSel)
        if (i < c.ocrFullSegments.length) c.ocrFullSegments[i],
      for (final i in _asrSel)
        if (i < c.asrSegments.length) c.asrSegments[i],
    ];
    if (merged.isEmpty) {
      SmartDialog.showToast('请先勾选要导出的字幕段');
      return;
    }
    final content = c.buildSrtContent(merged);
    setState(() => _busy = true);
    try {
      await StorageUtils.saveBytes2File(
        name: 'subtitle_${DateTime.now().millisecondsSinceEpoch}.srt',
        bytes: Uint8List.fromList(utf8.encode(content)),
        allowedExtensions: const ['srt'],
      );
    } catch (e) {
      SmartDialog.showToast('导出失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
