import 'dart:ui';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:get/get_core/get_core.dart';
import 'package:get/get_instance/src/bindings_interface.dart';
import 'package:get/get_navigation/get_navigation.dart';
import 'package:get/get_navigation/src/root/parse_route.dart';
import 'package:get/get_utils/get_utils.dart';

/// It replaces the Flutter Navigator, but needs no context.
/// You can to use navigator.push(YourRoute()) rather
/// Navigator.push(context, YourRoute());
NavigatorState? get navigator => GetNavigation(Get).key.currentState;

extension GetNavigation on GetInterface {
  /// **Navigation.push()** shortcut.<br><br>
  ///
  /// Pushes a new `page` to the stack
  ///
  /// It has the advantage of not needing context,
  /// so you can call from your business logic
  ///
  /// You can set a custom [transition], and a transition [duration].
  ///
  /// You can send any type of value to the other route in the [arguments].
  ///
  /// Just like native routing in Flutter, you can push a route
  /// as a [fullscreenDialog],
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// If you want the same behavior of ios that pops a route when the user drag,
  /// you can set [popGesture] to true
  ///
  /// If you're using the [Bindings] api, you must define it here
  ///
  /// By default, GetX will prevent you from push a route that you already in,
  /// if you want to push anyway, set [preventDuplicates] to false
  Future<T?>? to<T>(
    dynamic page, {
    int? id,
    String? routeName,
    dynamic arguments,
    Bindings? binding,
    bool preventDuplicates = true,
  }) {
    // var routeName = "/${page.runtimeType}";
    routeName ??= "/${page.runtimeType}";
    routeName = _cleanRouteName(routeName);
    if (preventDuplicates && routeName == currentRoute) {
      return null;
    }
    return global(id).currentState?.push<T>(
          GetPageRoute<T>(
            page: _resolvePage(page, 'to'),
            routeName: routeName,
            settings: RouteSettings(
              name: routeName,
              arguments: arguments,
            ),
            binding: binding,
          ),
        );
  }

  static GetPageBuilder _resolvePage(dynamic page, String method) {
    if (page is GetPageBuilder) {
      return page;
    } else if (page is Widget) {
      if (kDebugMode) {
        Get.log(
            '''WARNING, consider using: "Get.$method(() => Page())" instead of "Get.$method(Page())".
Using a widget function instead of a widget fully guarantees that the widget and its controllers will be removed from memory when they are no longer used.
      ''');
      }
      return () => page;
    } else if (page is String) {
      throw '''Unexpected String,
use toNamed() instead''';
    } else {
      throw '''Unexpected format,
you can only use widgets and widget functions here''';
    }
  }

  /// **Navigation.pushNamed()** shortcut.<br><br>
  ///
  /// Pushes a new named `page` to the stack.
  ///
  /// It has the advantage of not needing context, so you can call
  /// from your business logic.
  ///
  /// You can send any type of value to the other route in the [arguments].
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// By default, GetX will prevent you from push a route that you already in,
  /// if you want to push anyway, set [preventDuplicates] to false
  ///
  /// Note: Always put a slash on the route ('/page1'), to avoid unnexpected errors
  Future<T?>? toNamed<T>(
    String page, {
    dynamic arguments,
    int? id,
    bool preventDuplicates = true,
    Map<String, String>? parameters,
  }) {
    if (preventDuplicates && page == currentRoute) {
      return null;
    }

    if (parameters != null) {
      final uri = Uri(path: page, queryParameters: parameters);
      page = uri.toString();
    }

    return global(id).currentState?.pushNamed<T>(
          page,
          arguments: arguments,
        );
  }

  /// **Navigation.pushReplacementNamed()** shortcut.<br><br>
  ///
  /// Pop the current named `page` in the stack and push a new one in its place
  ///
  /// It has the advantage of not needing context, so you can call
  /// from your business logic.
  ///
  /// You can send any type of value to the other route in the [arguments].
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// By default, GetX will prevent you from push a route that you already in,
  /// if you want to push anyway, set [preventDuplicates] to false
  ///
  /// Note: Always put a slash on the route ('/page1'), to avoid unnexpected errors
  Future<T?>? offNamed<T>(
    String page, {
    dynamic arguments,
    int? id,
    bool preventDuplicates = true,
    Map<String, String>? parameters,
  }) {
    if (preventDuplicates && page == currentRoute) {
      return null;
    }

    if (parameters != null) {
      final uri = Uri(path: page, queryParameters: parameters);
      page = uri.toString();
    }
    return global(id).currentState?.pushReplacementNamed(
          page,
          arguments: arguments,
        );
  }

  /// **Navigation.popUntil()** shortcut.<br><br>
  ///
  /// Calls pop several times in the stack until [predicate] returns true
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// [predicate] can be used like this:
  /// `Get.until((route) => Get.currentRoute == '/home')`so when you get to home page,
  ///
  /// or also like this:
  /// `Get.until((route) => !Get.isDialogOpen())`, to make sure the
  /// dialog is closed
  void until(RoutePredicate predicate, {int? id}) {
    // if (key.currentState.mounted) // add this if appear problems on future with route navigate
    // when widget don't mounted
    return global(id).currentState?.popUntil(predicate);
  }

  /// **Navigation.pushAndRemoveUntil()** shortcut.<br><br>
  ///
  /// Push the given `page`, and then pop several pages in the stack until
  /// [predicate] returns true
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// Obs: unlike other get methods, this one you need to send a function
  /// that returns the widget to the page argument, like this:
  /// Get.offUntil(GetPageRoute(page: () => HomePage()), predicate)
  ///
  /// [predicate] can be used like this:
  /// `Get.offUntil(page, (route) => (route as GetPageRoute).routeName == '/home')`
  /// to pop routes in stack until home,
  /// or also like this:
  /// `Get.until((route) => !Get.isDialogOpen())`, to make sure the dialog
  /// is closed
  Future<T?>? offUntil<T>(Route<T> page, RoutePredicate predicate, {int? id}) {
    // if (key.currentState.mounted) // add this if appear problems on future with route navigate
    // when widget don't mounted
    return global(id).currentState?.pushAndRemoveUntil<T>(page, predicate);
  }

  /// **Navigation.pushNamedAndRemoveUntil()** shortcut.<br><br>
  ///
  /// Push the given named `page`, and then pop several pages in the stack
  /// until [predicate] returns true
  ///
  /// You can send any type of value to the other route in the [arguments].
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// [predicate] can be used like this:
  /// `Get.offNamedUntil(page, ModalRoute.withName('/home'))`
  /// to pop routes in stack until home,
  /// or like this:
  /// `Get.offNamedUntil((route) => !Get.isDialogOpen())`,
  /// to make sure the dialog is closed
  ///
  /// Note: Always put a slash on the route name ('/page1'), to avoid unexpected errors
  Future<T?>? offNamedUntil<T>(
    String page,
    RoutePredicate predicate, {
    int? id,
    dynamic arguments,
    Map<String, String>? parameters,
  }) {
    if (parameters != null) {
      final uri = Uri(path: page, queryParameters: parameters);
      page = uri.toString();
    }

    return global(id).currentState?.pushNamedAndRemoveUntil<T>(
          page,
          predicate,
          arguments: arguments,
        );
  }

  /// **Navigation.popAndPushNamed()** shortcut.<br><br>
  ///
  /// Pop the current named page and pushes a new `page` to the stack
  /// in its place
  ///
  /// You can send any type of value to the other route in the [arguments].
  /// It is very similar to `offNamed()` but use a different approach
  ///
  /// The `offNamed()` pop a page, and goes to the next. The
  /// `offAndToNamed()` goes to the next page, and removes the previous one.
  /// The route transition animation is different.
  Future<T?>? offAndToNamed<T>(
    String page, {
    dynamic arguments,
    int? id,
    dynamic result,
    Map<String, String>? parameters,
  }) {
    if (parameters != null) {
      final uri = Uri(path: page, queryParameters: parameters);
      page = uri.toString();
    }
    return global(id).currentState?.popAndPushNamed(
          page,
          arguments: arguments,
          result: result,
        );
  }

  /// **Navigation.removeRoute()** shortcut.<br><br>
  ///
  /// Remove a specific [route] from the stack
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  void removeRoute(Route<dynamic> route, {int? id}) {
    return global(id).currentState?.removeRoute(route);
  }

  /// **Navigation.pushNamedAndRemoveUntil()** shortcut.<br><br>
  ///
  /// Push a named `page` and pop several pages in the stack
  /// until [predicate] returns true. [predicate] is optional
  ///
  /// It has the advantage of not needing context, so you can
  /// call from your business logic.
  ///
  /// You can send any type of value to the other route in the [arguments].
  ///
  /// [predicate] can be used like this:
  /// `Get.until((route) => Get.currentRoute == '/home')`so when you get to home page,
  /// or also like
  /// `Get.until((route) => !Get.isDialogOpen())`, to make sure the dialog
  /// is closed
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// Note: Always put a slash on the route ('/page1'), to avoid unexpected errors
  Future<T?>? offAllNamed<T>(
    String newRouteName, {
    RoutePredicate? predicate,
    dynamic arguments,
    int? id,
    Map<String, String>? parameters,
  }) {
    if (parameters != null) {
      final uri = Uri(path: newRouteName, queryParameters: parameters);
      newRouteName = uri.toString();
    }

    return global(id).currentState?.pushNamedAndRemoveUntil<T>(
          newRouteName,
          predicate ?? (_) => false,
          arguments: arguments,
        );
  }

  /// **Navigation.popUntil()** shortcut.<br><br>
  ///
  /// Pop the current page, snackbar, dialog or bottomsheet in the stack
  ///
  /// if your set [closeOverlays] to true, Get.back() will close the
  /// currently open snackbar/dialog/bottomsheet AND the current page
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// It has the advantage of not needing context, so you can call
  /// from your business logic.
  void back<T>({
    T? result,
    bool canPop = true,
    int? id,
  }) {
    if (canPop) {
      if (global(id).currentState?.canPop() == true) {
        global(id).currentState?.pop<T>(result);
      }
    } else {
      global(id).currentState?.pop<T>(result);
    }
  }

  /// **Navigation.popUntil()** (with predicate) shortcut .<br><br>
  ///
  /// Close as many routes as defined by [times]
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  void close(int times, [int? id]) {
    if (times < 1) {
      times = 1;
    }
    var count = 0;
    var back = global(id).currentState?.popUntil((route) => count++ == times);

    return back;
  }

  /// **Navigation.pushReplacement()** shortcut .<br><br>
  ///
  /// Pop the current page and pushes a new `page` to the stack
  ///
  /// It has the advantage of not needing context,
  /// so you can call from your business logic
  ///
  /// You can set a custom [transition], define a Tween [curve],
  /// and a transition [duration].
  ///
  /// You can send any type of value to the other route in the [arguments].
  ///
  /// Just like native routing in Flutter, you can push a route
  /// as a [fullscreenDialog],
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// If you want the same behavior of ios that pops a route when the user drag,
  /// you can set [popGesture] to true
  ///
  /// If you're using the [Bindings] api, you must define it here
  ///
  /// By default, GetX will prevent you from push a route that you already in,
  /// if you want to push anyway, set [preventDuplicates] to false
  Future<T?>? off<T>(
    dynamic page, {
    int? id,
    String? routeName,
    dynamic arguments,
    Bindings? binding,
    bool preventDuplicates = true,
  }) {
    routeName ??= "/${page.runtimeType.toString()}";
    routeName = _cleanRouteName(routeName);
    if (preventDuplicates && routeName == currentRoute) {
      return null;
    }
    return global(id).currentState?.pushReplacement(
          GetPageRoute(
            page: _resolvePage(page, 'off'),
            binding: binding,
            settings: RouteSettings(
              arguments: arguments,
              name: routeName,
            ),
            routeName: routeName,
          ),
        );
  }

  ///
  /// Push a `page` and pop several pages in the stack
  /// until [predicate] returns true. [predicate] is optional
  ///
  /// It has the advantage of not needing context,
  /// so you can call from your business logic
  ///
  /// You can set a custom [transition], a [curve] and a transition [duration].
  ///
  /// You can send any type of value to the other route in the [arguments].
  ///
  /// Just like native routing in Flutter, you can push a route
  /// as a [fullscreenDialog],
  ///
  /// [predicate] can be used like this:
  /// `Get.until((route) => Get.currentRoute == '/home')`so when you get to home page,
  /// or also like
  /// `Get.until((route) => !Get.isDialogOpen())`, to make sure the dialog
  /// is closed
  ///
  /// [id] is for when you are using nested navigation,
  /// as explained in documentation
  ///
  /// If you want the same behavior of ios that pops a route when the user drag,
  /// you can set [popGesture] to true
  ///
  /// If you're using the [Bindings] api, you must define it here
  ///
  /// By default, GetX will prevent you from push a route that you already in,
  /// if you want to push anyway, set [preventDuplicates] to false
  Future<T?>? offAll<T>(
    dynamic page, {
    RoutePredicate? predicate,
    bool opaque = false,
    int? id,
    String? routeName,
    dynamic arguments,
    Bindings? binding,
  }) {
    routeName ??= "/${page.runtimeType.toString()}";
    routeName = _cleanRouteName(routeName);
    return global(id).currentState?.pushAndRemoveUntil<T>(
          GetPageRoute<T>(
            page: _resolvePage(page, 'offAll'),
            binding: binding,
            settings: RouteSettings(
              name: routeName,
              arguments: arguments,
            ),
            routeName: routeName,
          ),
          predicate ?? (route) => false,
        );
  }

  /// Takes a route [name] String generated by [to], [off], [offAll]
  /// (and similar context navigation methods), cleans the extra chars and
  /// accommodates the format.
  /// TODO: check for a more "appealing" URL naming convention.
  /// `() => MyHomeScreenView` becomes `/my-home-screen-view`.
  static String _cleanRouteName(String name) {
    name = name.replaceAll('() => ', '');

    /// uncommonent for URL styling.
    // name = name.paramCase!;
    if (!name.startsWith('/')) {
      name = '/$name';
    }
    return Uri.tryParse(name)?.toString() ?? name;
  }

  /// change default config of Get
  void config({
    Transition? defaultTransition,
  }) {
    if (defaultTransition != null) {
      _getxController.defaultTransition = defaultTransition;
    }
  }

  Future<void> updateLocale(Locale l) {
    Get.locale = l;
    return forceAppUpdate();
  }

  /// As a rule, Flutter knows which widget to update,
  /// so this command is rarely needed. We can mention situations
  /// where you use const so that widgets are not updated with setState,
  /// but you want it to be forcefully updated when an event like
  /// language change happens. using context to make the widget dirty
  /// for performRebuild() is a viable solution.
  /// However, in situations where this is not possible, or at least,
  /// is not desired by the developer, the only solution for updating
  /// widgets that Flutter does not want to update is to use reassemble
  /// to forcibly rebuild all widgets. Attention: calling this function will
  /// reconstruct the application from the sketch, use this with caution.
  /// Your entire application will be rebuilt, and touch events will not
  /// work until the end of rendering.
  Future<void> forceAppUpdate() {
    return engine.performReassemble();
  }

  void appUpdate() => _getxController.update();

  void changeTheme(ThemeData theme) {
    _getxController.setTheme(theme);
  }

  void changeThemeMode(ThemeMode themeMode) {
    _getxController.setThemeMode(themeMode);
  }

  GlobalKey<NavigatorState>? addKey(GlobalKey<NavigatorState> newKey) {
    return _getxController.addKey(newKey);
  }

  GlobalKey<NavigatorState>? nestedKey(dynamic key) {
    keys.putIfAbsent(
      key,
      () => GlobalKey<NavigatorState>(
        debugLabel: 'Getx nested key: ${key.toString()}',
      ),
    );
    return keys[key];
  }

  GlobalKey<NavigatorState> global(int? k) {
    GlobalKey<NavigatorState> newKey;
    if (k == null) {
      newKey = key;
    } else {
      if (!keys.containsKey(k)) {
        throw 'Route id ($k) not found';
      }
      newKey = keys[k]!;
    }

    if (newKey.currentContext == null && !testMode) {
      throw """You are trying to use contextless navigation without
      a GetMaterialApp or Get.key.
      If you are testing your app, you can use:
      [Get.testMode = true], or if you are running your app on
      a physical device or emulator, you must exchange your [MaterialApp]
      for a [GetMaterialApp].
      """;
    }

    return newKey;
  }

  /// give current arguments
  dynamic get arguments => routing.args;

  /// give name from current route
  String get currentRoute => routing.current;

  /// give name from previous route
  String get previousRoute => routing.previous;

  /// check a raw current route
  Route<dynamic>? get rawRoute => routing.route;

  /// check if default opaque route is enable
  bool get isOpaqueRouteDefault => true;

  /// give access to currentContext
  BuildContext? get context => key.currentContext;

  /// give access to current Overlay Context
  BuildContext? get overlayContext {
    BuildContext? overlay;
    key.currentState?.overlay?.context.visitChildElements((element) {
      overlay = element;
    });
    return overlay;
  }

  ///The current [WidgetsBinding]
  WidgetsBinding get engine {
    return WidgetsFlutterBinding.ensureInitialized();
  }

  Locale? get deviceLocale => PlatformDispatcher.instance.locale;

  ///The system-reported text scale.
  double get textScaleFactor => PlatformDispatcher.instance.textScaleFactor;

  /// Check if dark mode theme is enable on platform on android Q+
  bool get isPlatformDarkMode =>
      (PlatformDispatcher.instance.platformBrightness == Brightness.dark);

  /// give access to FocusScope.of(context)
  FocusNode? get focusScope => FocusManager.instance.primaryFocus;

  GlobalKey<NavigatorState> get key => _getxController.key;

  Map<dynamic, GlobalKey<NavigatorState>> get keys => _getxController.keys;

  GetMaterialController get rootController => _getxController;

  Transition get defaultTransition => _getxController.defaultTransition;

  Routing get routing => _getxController.routing;

  Map<String, String?> get parameters => _getxController.parameters;

  set parameters(Map<String, String?> newParameters) =>
      _getxController.parameters = newParameters;

  bool get testMode => _getxController.testMode;

  set testMode(bool isTest) => _getxController.testMode = isTest;

  void resetRootNavigator() {
    _getxController = GetMaterialController();
  }

  static GetMaterialController _getxController = GetMaterialController();
}

extension NavTwoExt on GetInterface {
  void addPages(List<GetPage> getPages) {
    routeTree.addRoutes(getPages);
  }

  void clearRouteTree() {
    _routeTree.routes.clear();
  }

  static final _routeTree = ParseRouteTree(routes: []);

  ParseRouteTree get routeTree => _routeTree;

  void addPage(GetPage getPage) {
    routeTree.addRoute(getPage);
  }

  /// Casts the stored router delegate to a desired type
  TDelegate? delegate<TDelegate extends RouterDelegate<TPage>, TPage>() =>
      routerDelegate as TDelegate?;

  // // ignore: use_setters_to_change_properties
  // void setDefaultDelegate(RouterDelegate? delegate) {
  //   _routerDelegate = delegate;
  // }

  // GetDelegate? getDelegate() => delegate<GetDelegate, GetNavConfig>();

  GetInformationParser createInformationParser({String initialRoute = '/'}) {
    if (routeInformationParser == null) {
      return routeInformationParser = GetInformationParser(
        initialRoute: initialRoute,
      );
    } else {
      return routeInformationParser as GetInformationParser;
    }
  }

  // static GetDelegate? _delegate;

  GetDelegate get rootDelegate => createDelegate();

  GetDelegate createDelegate({
    GetPage<dynamic>? notFoundRoute,
    List<NavigatorObserver>? navigatorObservers,
    TransitionDelegate<dynamic>? transitionDelegate,
    PopMode backButtonPopMode = PopMode.History,
    PreventDuplicateHandlingMode preventDuplicateHandlingMode =
        PreventDuplicateHandlingMode.ReorderRoutes,
  }) {
    if (routerDelegate == null) {
      return routerDelegate = GetDelegate(
        notFoundRoute: notFoundRoute,
        navigatorObservers: navigatorObservers,
        transitionDelegate: transitionDelegate,
        backButtonPopMode: backButtonPopMode,
        preventDuplicateHandlingMode: preventDuplicateHandlingMode,
      );
    } else {
      return routerDelegate as GetDelegate;
    }
  }
}
