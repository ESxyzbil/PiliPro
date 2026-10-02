import 'package:PiliPlus/common/widgets/glass.dart';
import 'package:material_ui/material_ui.dart';

/// 信息卡片包装：给设置项/动态项等列表信息加卡片背景（可毛玻璃）。
Widget buildInfoCard(Widget child, {EdgeInsetsGeometry? padding}) => Padding(
  padding: padding ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
  child: GlassContainer(
    kind: GlassKind.infoCard,
    borderRadius: BorderRadius.circular(10),
    child: child,
  ),
);
