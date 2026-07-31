p = 'lib/utils/theme_utils.dart'
s = open(p, encoding='utf-8').read()

old = """/// 过渡动画：新页面淡入 + 轻微上滑；旧页面同步淡出。
/// 无 scrim 遮罩，过渡期间露出的区域透明，直接透出背景层。
class FadePreviousPageTransitionsBuilder extends PageTransitionsBuilder {
  const FadePreviousPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      // 上一页淡出：secondaryAnimation 0→1 时 opacity 1→0
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
      ),
      child: FadeTransition(
        // 新页面淡入
        opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curved),
        child: SlideTransition(
          // 新页面轻微上滑
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      ),
    );
  }
}
"""

new = """/// 过渡动画：新页面淡入 + 轻微上滑；旧页面先淡出。
/// 错开时序：前 50% 旧页淡出（新页透明），后 50% 新页淡入（旧页已透明），
/// 新旧页面不会同时半透明叠加，避免产生白色混合层。
/// 无 scrim 遮罩，过渡期间露出的区域透明，直接透出背景层。
class FadePreviousPageTransitionsBuilder extends PageTransitionsBuilder {
  const FadePreviousPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      // 上一页淡出：前 50% 完成（1→0），后 50% 保持透明
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: const _ShiftCurve(out: true),
        ),
      ),
      child: FadeTransition(
        // 新页面淡入：前 50% 保持透明，后 50% 0→1
        opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(
            parent: animation,
            curve: const _ShiftCurve(out: false),
          ),
        ),
        child: SlideTransition(
          // 新页面轻微上滑
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      ),
    );
  }
}

/// 错开时序曲线：
/// - out=false（新页）：前 50% 保持透明，后 50% 淡入到 1
/// - out=true（旧页）：前 50% 淡出到 0，后 50% 保持透明
/// 正反方向天然对称（pop 时新页前段淡出、旧页后段淡入）。
class _ShiftCurve extends Curve {
  const _ShiftCurve({required this.out});

  final bool out;

  @override
  double transformInternal(double t) {
    if (out) {
      if (t >= 0.5) return 0;
      return 1 - Curves.easeOutCubic.transform(t / 0.5);
    }
    if (t <= 0.5) return 0;
    return Curves.easeOutCubic.transform((t - 0.5) / 0.5);
  }
}
"""

print('count:', s.count(old))
if s.count(old) == 1:
    open(p, 'w', encoding='utf-8').write(s.replace(old, new))
    print('replaced')
else:
    print('FAILED')
