import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:PiliPlus/pages/dynamics/view.dart';
import 'package:PiliPlus/pages/home/view.dart';
import 'package:PiliPlus/pages/mine/view.dart';
import 'package:material_ui/material_ui.dart';

enum NavigationBarType implements EnumWithLabel {
  home(
    '首页',
    Icon(Icons.home_outlined),
    Icon(Icons.home),
    HomePage(),
  ),
  dynamics(
    '动态',
    Icon(CustomIcons.motion_photos_on_outlined),
    Icon(CustomIcons.motion_photos_on),
    DynamicsPage(),
  ),
  mine(
    '我的',
    Icon(Icons.person_outline),
    Icon(Icons.person),
    MinePage(),
  ),
  // 第四个入口：「网页」——不是主页内容页，点击由 MainController.setIndex
  // 拦截，直接在多页面标签页中打开网页（见 PageUtils.openBiliWeb）。
  // page 只是占位（该入口永远不会成为主页 PageView 的当前页）。
  web(
    '网页',
    Icon(Icons.public_outlined, size: 24),
    Icon(Icons.public, size: 24),
    SizedBox.shrink(),
  ),
  ;

  /// 是否为「启动器入口」：点击不切换主页内容页，而是触发外部动作
  /// （当前仅 web：在标签页中打开哔哩哔哩网页版）。
  bool get isLauncher => this == NavigationBarType.web;

  @override
  final String label;
  final Icon icon;
  final Icon selectIcon;
  final Widget page;

  const NavigationBarType(this.label, this.icon, this.selectIcon, this.page);
}
