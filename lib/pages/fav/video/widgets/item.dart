import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/cover_flight.dart';
import 'package:PiliPlus/common/widgets/image/image_save.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/list.dart';
import 'package:PiliPlus/services/shortcut_service.dart';
import 'package:PiliPlus/utils/bili_utils.dart';
import 'package:material_ui/material_ui.dart';

class FavVideoItem extends StatelessWidget {
  final String heroTag;
  final FavFolderInfo item;

  /// 点击回调：参数为源封面在屏幕上的矩形（可能为 null），用于标签模式下的封面飞行
  final void Function(Rect? coverRect)? onTap;
  final VoidCallback? onLongPress;

  const FavVideoItem({
    super.key,
    this.onTap,
    this.onLongPress,
    required this.heroTag,
    required this.item,
  });

  @override
  Widget build(BuildContext context) {
    BuildContext? coverContext;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap == null
            ? null
            : () => onTap!(CoverFlight.rectOf(coverContext)),
        onLongPress: onLongPress ?? () => _showMenu(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: Style.aspectRatio,
                child: LayoutBuilder(
                  builder: (context, boxConstraints) {
                    return Builder(
                      builder: (ctx) {
                        coverContext = ctx;
                        return Hero(
                          tag: heroTag,
                          child: NetworkImgLayer(
                            src: item.cover,
                            width: boxConstraints.maxWidth,
                            height: boxConstraints.maxHeight,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              content(context),
            ],
          ),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('保存封面'),
                onTap: () {
                  Navigator.pop(ctx);
                  imageSaveDialog(title: item.title, cover: item.cover);
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_to_home_screen_outlined),
                title: const Text('添加到桌面长按菜单'),
                subtitle: const Text('长按桌面图标后在弹出菜单里选择'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await ShortcutService.addCollectionShortcut(
                    item.id,
                    item.title,
                  );
                  if (!context.mounted) return;
                  _toast(
                    context,
                    ok
                        ? '已加入长按菜单：${item.title}'
                        : '系统未登记该快捷方式，请改用「固定到主屏幕」',
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('固定到主屏幕'),
                subtitle: const Text('弹系统确认框，直接在桌面生成图标'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await ShortcutService.pinCollectionShortcut(
                    item.id,
                    item.title,
                  );
                  if (context.mounted && !ok) {
                    _toast(context, '当前桌面不支持固定快捷方式');
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Widget content(BuildContext context) {
    final theme = Theme.of(context);
    final fontSize = theme.textTheme.labelMedium!.fontSize;
    final color = theme.colorScheme.outline;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            textAlign: TextAlign.start,
            style: const TextStyle(
              letterSpacing: 0.3,
            ),
          ),
          if (item.intro?.isNotEmpty == true)
            Text(
              item.intro!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                color: color,
              ),
            ),
          Text(
            '${item.mediaCount}个内容',
            style: TextStyle(
              fontSize: fontSize,
              color: color,
            ),
          ),
          const Spacer(),
          Text(
            BiliUtils.isPublicFavText(item.attr),
            style: TextStyle(
              fontSize: fontSize,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
