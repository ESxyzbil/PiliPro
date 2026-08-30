import 'dart:io';

import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

List<SettingsModel> get layoutSettings => [
  if (Platform.isAndroid) ...[
    NormalModel(
      title: '应用内PPI',
      getSubtitle: () {
        final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
        final devicePpi = (160 * dpr).round();
        final currentPpi = (devicePpi * Pref.uiScale).round();
        final desc = currentPpi == devicePpi ? '默认' : '${currentPpi}PPI';
        return '当前: $desc（设备: ${devicePpi}PPI）';
      },
      leading: const Icon(Icons.zoom_in_outlined),
      onTap: (context, setState) => Get.toNamed('/ppiSetting'),
    ),
    SplitModel(
      normalModel: const NormalModel.split(
        title: '圆形屏幕适配',
        subtitle: '顶栏/底栏内容居中，避免内容显示在圆形有效显示区域外',
        leading: Icon(Icons.screen_lock_rotation_outlined),
      ),
      switchModel: SwitchModel.split(
        setKey: SettingBoxKey.circularScreen,
        defaultVal: false,
        onChanged: (value) {
          Get.appUpdate();
        },
      ),
    ),
  ],
  if (PlatformUtils.isDesktop) ...[
    SplitModel(
      normalModel: const NormalModel.split(
        title: '桌面端多页面标签',
        subtitle: '侧边标签栏打开视频/专栏，可多开切换、关闭',
        leading: Icon(Icons.tab_outlined),
      ),
      switchModel: SwitchModel.split(
        setKey: SettingBoxKey.desktopTabs,
        defaultVal: true,
      ),
    ),
    SplitModel(
      normalModel: const NormalModel.split(
        title: '切走标签自动转音频',
        subtitle: '切走正在播放的视频标签时，以音频模式继续播',
        leading: Icon(Icons.headphones_outlined),
      ),
      switchModel: SwitchModel.split(
        setKey: SettingBoxKey.tabAutoAudio,
        defaultVal: true,
      ),
    ),
  ],
];
