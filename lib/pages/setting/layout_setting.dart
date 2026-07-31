import 'package:PiliPlus/pages/setting/models/layout_settings.dart';
import 'package:flutter/material.dart';

class LayoutSetting extends StatefulWidget {
  const LayoutSetting({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  State<LayoutSetting> createState() => _LayoutSettingState();
}

class _LayoutSettingState extends State<LayoutSetting> {
  final settings = layoutSettings;

  @override
  Widget build(BuildContext context) {
    final showAppBar = widget.showAppBar;
    final padding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: showAppBar ? AppBar(title: const Text('布局设置')) : null,
      body: ListView.builder(
        padding: EdgeInsets.only(
          left: showAppBar ? padding.left : 0,
          right: showAppBar ? padding.right : 0,
          bottom: padding.bottom + 100,
        ),
        itemCount: settings.length,
        itemBuilder: (context, index) => settings[index].widget,
      ),
    );
  }
}
