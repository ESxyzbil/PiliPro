import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get/get_navigation/src/router_report.dart';
import 'package:get/get_navigation/src/routes/get_transition_mixin.dart';

mixin PageRouteReportMixin<T> on Route<T> {
  @override
  void install() {
    super.install();
    RouterReportManager.reportCurrentRoute(this);
  }

  @override
  void dispose() {
    super.dispose();
    RouterReportManager.reportRouteDispose(this);
  }
}

class GetPageRoute<T> extends PageRoute<T>
    with GetPageRouteTransitionMixin<T>, PageRouteReportMixin {
  /// Creates a page route for use in an iOS designed app.
  ///
  /// The [builder], [maintainState], and [fullscreenDialog] arguments must not
  /// be null.
  GetPageRoute({
    super.settings,
    this.parameter,
    this.barrierDismissible = false,
    this.barrierColor,
    this.binding,
    this.bindings,
    this.routeName,
    this.page,
    this.title,
    this.barrierLabel,
    this.maintainState = true,
    this.middlewares,
  });

  @override
  final Duration transitionDuration = const Duration(milliseconds: 300);
  final GetPageBuilder? page;
  final String? routeName;
  final Bindings? binding;
  final Map<String, String>? parameter;
  final List<Bindings>? bindings;

  @override
  final bool opaque = true;

  @override
  final bool barrierDismissible;
  final List<GetMiddleware>? middlewares;

  @override
  final Color? barrierColor;

  @override
  final String? barrierLabel;

  @override
  final bool maintainState;

  @override
  void dispose() {
    super.dispose();
    MiddlewareRunner(middlewares).runOnPageDispose();
  }

  Widget? _child;

  Widget _getChild() {
    if (_child != null) return _child!;
    final middlewareRunner = MiddlewareRunner(middlewares);

    final localbindings = [
      if (bindings != null) ...bindings!,
      if (binding != null) ...[binding!]
    ];
    final bindingsToBind = middlewareRunner.runOnBindingsStart(localbindings);
    if (bindingsToBind != null) {
      for (final binding in bindingsToBind) {
        binding.dependencies();
      }
    }

    final pageToBuild = middlewareRunner.runOnPageBuildStart(page)!;
    _child = middlewareRunner.runOnPageBuilt(pageToBuild());
    return _child!;
  }

  @override
  Widget buildContent(BuildContext context) {
    return _getChild();
  }

  @override
  final String? title;

  @override
  String get debugLabel => '${super.debugLabel}(${settings.name})';
}
