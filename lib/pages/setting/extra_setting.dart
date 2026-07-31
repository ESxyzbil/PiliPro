import 'package:PiliPlus/pages/setting/widgets/info_card_item.dart';
import 'package:PiliPlus/pages/setting/models/extra_settings.dart';
import 'package:flutter/material.dart';

class ExtraSetting extends StatefulWidget {
  const ExtraSetting({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  State<ExtraSetting> createState() => _ExtraSettingState();
}

class _ExtraSettingState extends State<ExtraSetting> {
  final settings = extraSettings;

  @override
  Widget build(BuildContext context) {
    final showAppBar = widget.showAppBar;
    final padding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: showAppBar ? AppBar(title: const Text('鍏跺畠璁剧疆')) : null,
      body: ListView.builder(
        padding: EdgeInsets.only(
          left: showAppBar ? padding.left : 0,
          right: showAppBar ? padding.right : 0,
          bottom: padding.bottom + 100,
        ),
        itemCount: settings.length,
        itemBuilder: (context, index) => buildInfoCard(settings[index].widget),
      ),
    );
  }
}

