import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:get/get_core/get_core.dart';
import 'package:get/get_navigation/get_navigation.dart';
import 'package:get/get_navigation/src/router_report.dart';
import 'package:get/instance_manager.dart';

/// Extracts the name of a route based on it's instance type
/// or null if not possible.
String? _extractRouteName(Route? route) {
  if (route?.settings.name != null) {
    return route!.settings.name;
  }

  if (route is GetPageRoute) {
    return route.routeName;
  }

  if (route is DialogRoute) {
    return 'DIALOG ${route.hashCode}';
  }

  return null;
}

class GetObserver extends NavigatorObserver {
  final Function(Routing?)? routing;

  final Routing? _routeSend;

  GetObserver([this.routing, this._routeSend]);

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);

    if (kDebugMode && route is GetPageRoute) {
      Get.log("CLOSE TO ROUTE ${_extractRouteName(route)}");
    }
    if (previousRoute != null) {
      RouterReportManager.reportCurrentRoute(previousRoute);
    }

    // Here we use a 'inverse didPush set', meaning that we use
    // previous route instead of 'route' because this is
    // a 'inverse push'
    _routeSend?.update((value) {
      // Only PageRoute is allowed to change current value
      if (previousRoute is PageRoute) {
        final previousRouteName = _extractRouteName(previousRoute) ?? '';
        value
          ..current = previousRouteName
          ..previous = previousRouteName;
      } else if (value.previous.isNotEmpty) {
        value.current = value.previous;
      }

      value
        ..args = previousRoute?.settings.arguments
        ..route = previousRoute;
    });

    routing?.call(_routeSend);
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    final newRouteName = _extractRouteName(route);
    if (kDebugMode && route is GetPageRoute) {
      Get.log("GOING TO ROUTE $newRouteName");
    }

    RouterReportManager.reportCurrentRoute(route);
    _routeSend?.update((value) {
      // Only PageRoute is allowed to change current value
      if (route is PageRoute) {
        value.current = newRouteName ?? '';
      }
      final previousRouteName = _extractRouteName(previousRoute);
      if (previousRouteName != null) {
        value.previous = previousRouteName;
      }

      value
        ..args = route.settings.arguments
        ..route = route;
    });

    if (routing != null) {
      routing!(_routeSend);
    }
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    final routeName = _extractRouteName(route);

    if (kDebugMode) Get.log("REMOVING ROUTE $routeName");

    _routeSend?.update((value) {
      value
        ..route = previousRoute
        ..previous = routeName ?? '';
    });

    if (route is GetPageRoute) {
      RouterReportManager.reportRouteWillDispose(route);
    }
    routing?.call(_routeSend);
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    final newName = _extractRouteName(newRoute);
    final oldName = _extractRouteName(oldRoute);

    if (kDebugMode) {
      Get.log("REPLACE ROUTE $oldName");
      Get.log("NEW ROUTE $newName");
    }

    if (newRoute != null) {
      RouterReportManager.reportCurrentRoute(newRoute);
    }

    _routeSend?.update((value) {
      // Only PageRoute is allowed to change current value
      if (newRoute is PageRoute) {
        value.current = newName ?? '';
      }

      value
        ..args = newRoute?.settings.arguments
        ..route = newRoute
        ..previous = '$oldName';
    });
    if (oldRoute is GetPageRoute) {
      RouterReportManager.reportRouteWillDispose(oldRoute);
    }

    routing?.call(_routeSend);
  }
}

class Routing {
  String current;
  String previous;
  dynamic args;
  Route<dynamic>? route;

  Routing({
    this.current = '',
    this.previous = '',
    this.args,
    this.route,
  });

  void update(void Function(Routing value) fn) {
    fn(this);
  }
}
