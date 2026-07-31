import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get_core/get_core.dart';
import 'package:get/get_instance/get_instance.dart';
import 'package:get/get_navigation/get_navigation.dart';
import 'package:get/get_state_manager/get_state_manager.dart';
import 'package:get/get_utils/get_utils.dart';

class GetMaterialApp extends StatelessWidget {
  final GlobalKey<NavigatorState>? navigatorKey;

  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;
  final Widget? home;
  final Map<String, WidgetBuilder>? routes;
  final String? initialRoute;
  final RouteFactory? onGenerateRoute;
  final InitialRouteListFactory? onGenerateInitialRoutes;
  final RouteFactory? onUnknownRoute;
  final List<NavigatorObserver>? navigatorObservers;
  final TransitionBuilder? builder;
  final String title;
  final GenerateAppTitle? onGenerateTitle;
  final ThemeData? theme;
  final ThemeData? darkTheme;
  final ThemeMode themeMode;
  final Color? color;
  final Map<String, Map<String, String>>? translationsKeys;
  final Translations? translations;
  final TextDirection? textDirection;
  final Locale? locale;
  final Locale? fallbackLocale;
  final Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates;
  final LocaleListResolutionCallback? localeListResolutionCallback;
  final LocaleResolutionCallback? localeResolutionCallback;
  final Iterable<Locale> supportedLocales;
  final bool showPerformanceOverlay;
  final bool checkerboardRasterCacheImages;
  final bool checkerboardOffscreenLayers;
  final bool showSemanticsDebugger;
  final bool debugShowCheckedModeBanner;
  final Map<LogicalKeySet, Intent>? shortcuts;
  final ScrollBehavior? scrollBehavior;
  final ThemeData? highContrastTheme;
  final ThemeData? highContrastDarkTheme;
  final Map<Type, Action<Intent>>? actions;
  final bool debugShowMaterialGrid;
  final ValueChanged<Routing?>? routingCallback;
  final Transition? defaultTransition;
  final VoidCallback? onInit;
  final VoidCallback? onReady;
  final VoidCallback? onDispose;
  final bool? enableLog;
  final LogWriterCallback? logWriterCallback;
  final SmartManagement smartManagement;
  final Bindings? initialBinding;
  final bool? defaultGlobalState;
  final List<GetPage>? getPages;
  final GetPage? unknownRoute;
  final RouteInformationProvider? routeInformationProvider;
  final RouteInformationParser<Object>? routeInformationParser;
  final RouterDelegate<Object>? routerDelegate;
  final BackButtonDispatcher? backButtonDispatcher;
  final bool useInheritedMediaQuery;

  const GetMaterialApp({
    super.key,
    this.navigatorKey,
    this.scaffoldMessengerKey,
    this.home,
    Map<String, Widget Function(BuildContext)> this.routes =
        const <String, WidgetBuilder>{},
    this.initialRoute,
    this.onGenerateRoute,
    this.onGenerateInitialRoutes,
    this.onUnknownRoute,
    this.useInheritedMediaQuery = false,
    List<NavigatorObserver> this.navigatorObservers =
        const <NavigatorObserver>[],
    this.builder,
    this.textDirection,
    this.title = '',
    this.onGenerateTitle,
    this.color,
    this.theme,
    this.darkTheme,
    this.themeMode = ThemeMode.system,
    this.locale,
    this.fallbackLocale,
    this.localizationsDelegates,
    this.localeListResolutionCallback,
    this.localeResolutionCallback,
    this.supportedLocales = const <Locale>[Locale('en', 'US')],
    this.debugShowMaterialGrid = false,
    this.showPerformanceOverlay = false,
    this.checkerboardRasterCacheImages = false,
    this.checkerboardOffscreenLayers = false,
    this.showSemanticsDebugger = false,
    this.debugShowCheckedModeBanner = true,
    this.shortcuts,
    this.scrollBehavior,
    this.translationsKeys,
    this.translations,
    this.onInit,
    this.onReady,
    this.onDispose,
    this.routingCallback,
    this.defaultTransition,
    this.getPages,
    this.enableLog = kDebugMode,
    this.logWriterCallback,
    this.defaultGlobalState,
    this.smartManagement = SmartManagement.full,
    this.initialBinding,
    this.unknownRoute,
    this.highContrastTheme,
    this.highContrastDarkTheme,
    this.actions,
  })  : routeInformationProvider = null,
        routeInformationParser = null,
        routerDelegate = null,
        backButtonDispatcher = null;

  GetMaterialApp.router({
    super.key,
    this.routeInformationProvider,
    this.scaffoldMessengerKey,
    RouteInformationParser<Object>? routeInformationParser,
    RouterDelegate<Object>? routerDelegate,
    this.backButtonDispatcher,
    this.builder,
    this.title = '',
    this.onGenerateTitle,
    this.color,
    this.theme,
    this.darkTheme,
    this.useInheritedMediaQuery = false,
    this.highContrastTheme,
    this.highContrastDarkTheme,
    this.themeMode = ThemeMode.system,
    this.locale,
    this.localizationsDelegates,
    this.localeListResolutionCallback,
    this.localeResolutionCallback,
    this.supportedLocales = const <Locale>[Locale('en', 'US')],
    this.debugShowMaterialGrid = false,
    this.showPerformanceOverlay = false,
    this.checkerboardRasterCacheImages = false,
    this.checkerboardOffscreenLayers = false,
    this.showSemanticsDebugger = false,
    this.debugShowCheckedModeBanner = true,
    this.shortcuts,
    this.scrollBehavior,
    this.actions,
    this.translationsKeys,
    this.translations,
    this.textDirection,
    this.fallbackLocale,
    this.routingCallback,
    this.defaultTransition,
    this.onInit,
    this.onReady,
    this.onDispose,
    this.enableLog = kDebugMode,
    this.logWriterCallback,
    this.smartManagement = SmartManagement.full,
    this.initialBinding,
    this.defaultGlobalState,
    this.getPages,
    this.navigatorObservers,
    this.unknownRoute,
  })  : routerDelegate = routerDelegate ??= Get.createDelegate(
          notFoundRoute: unknownRoute,
        ),
        routeInformationParser =
            routeInformationParser ??= Get.createInformationParser(
          initialRoute: getPages?.first.name ?? '/',
        ),
        //navigatorObservers = null,
        navigatorKey = null,
        onGenerateRoute = null,
        home = null,
        onGenerateInitialRoutes = null,
        onUnknownRoute = null,
        routes = null,
        initialRoute = null {
    Get.routerDelegate = routerDelegate;
    Get.routeInformationParser = routeInformationParser;
  }

  @override
  Widget build(BuildContext context) => GetBuilder<GetMaterialController>(
        init: Get.rootController,
        dispose: (d) {
          onDispose?.call();
        },
        initState: (i) {
          Get.engine.addPostFrameCallback((timeStamp) {
            onReady?.call();
          });
          if (locale != null) Get.locale = locale;

          if (fallbackLocale != null) Get.fallbackLocale = fallbackLocale;

          if (translations != null) {
            Get.addTranslations(translations!.keys);
          } else if (translationsKeys != null) {
            Get.addTranslations(translationsKeys!);
          }

          initialBinding?.dependencies();
          if (getPages != null) {
            Get.addPages(getPages!);
          }

          //Get.setDefaultDelegate(routerDelegate);
          Get.smartManagement = smartManagement;
          onInit?.call();

          Get.config(
            defaultTransition: defaultTransition ?? Get.defaultTransition,
          );
        },
        builder: (controller) => routerDelegate != null
            ? MaterialApp.router(
                routerDelegate: routerDelegate!,
                routeInformationParser: routeInformationParser!,
                backButtonDispatcher: backButtonDispatcher,
                routeInformationProvider: routeInformationProvider,
                key: controller.unikey,
                builder: builder,
                title: title,
                onGenerateTitle: onGenerateTitle,
                color: color,
                theme: controller.theme ?? theme ?? ThemeData.fallback(),
                darkTheme: controller.darkTheme ??
                    darkTheme ??
                    theme ??
                    ThemeData.fallback(),
                themeMode: controller.themeMode ?? themeMode,
                locale: Get.locale ?? locale,
                scaffoldMessengerKey:
                    scaffoldMessengerKey ?? controller.scaffoldMessengerKey,
                localizationsDelegates: localizationsDelegates,
                localeListResolutionCallback: localeListResolutionCallback,
                localeResolutionCallback: localeResolutionCallback,
                supportedLocales: supportedLocales,
                debugShowMaterialGrid: debugShowMaterialGrid,
                showPerformanceOverlay: showPerformanceOverlay,
                checkerboardRasterCacheImages: checkerboardRasterCacheImages,
                checkerboardOffscreenLayers: checkerboardOffscreenLayers,
                showSemanticsDebugger: showSemanticsDebugger,
                debugShowCheckedModeBanner: debugShowCheckedModeBanner,
                shortcuts: shortcuts,
                scrollBehavior: scrollBehavior,
                // useInheritedMediaQuery: useInheritedMediaQuery,
              )
            : MaterialApp(
                key: controller.unikey,
                navigatorKey: (navigatorKey == null
                    ? Get.key
                    : Get.addKey(navigatorKey!)),
                scaffoldMessengerKey:
                    scaffoldMessengerKey ?? controller.scaffoldMessengerKey,
                home: home,
                routes: routes ?? const <String, WidgetBuilder>{},
                initialRoute: initialRoute,
                onGenerateRoute:
                    (getPages != null ? generator : onGenerateRoute),
                onGenerateInitialRoutes: (getPages == null || home != null)
                    ? onGenerateInitialRoutes
                    : initialRoutesGenerate,
                onUnknownRoute: onUnknownRoute,
                navigatorObservers: (navigatorObservers == null
                    ? <NavigatorObserver>[
                        GetObserver(routingCallback, Get.routing)
                      ]
                    : <NavigatorObserver>[
                        GetObserver(routingCallback, Get.routing)
                      ]
                  ..addAll(navigatorObservers!)),
                builder: builder,
                title: title,
                onGenerateTitle: onGenerateTitle,
                color: color,
                theme: controller.theme ?? theme ?? ThemeData.fallback(),
                darkTheme: controller.darkTheme ??
                    darkTheme ??
                    theme ??
                    ThemeData.fallback(),
                themeMode: controller.themeMode ?? themeMode,
                locale: Get.locale ?? locale,
                localizationsDelegates: localizationsDelegates,
                localeListResolutionCallback: localeListResolutionCallback,
                localeResolutionCallback: localeResolutionCallback,
                supportedLocales: supportedLocales,
                debugShowMaterialGrid: debugShowMaterialGrid,
                showPerformanceOverlay: showPerformanceOverlay,
                checkerboardRasterCacheImages: checkerboardRasterCacheImages,
                checkerboardOffscreenLayers: checkerboardOffscreenLayers,
                showSemanticsDebugger: showSemanticsDebugger,
                debugShowCheckedModeBanner: debugShowCheckedModeBanner,
                shortcuts: shortcuts,
                scrollBehavior: scrollBehavior,
                // useInheritedMediaQuery: useInheritedMediaQuery,
                //   actions: actions,
              ),
      );

  Route<dynamic> generator(RouteSettings settings) {
    return PageRedirect(settings: settings, unknownRoute: unknownRoute).page();
  }

  List<Route<dynamic>> initialRoutesGenerate(String name) {
    return [
      PageRedirect(
        settings: RouteSettings(name: name),
        unknownRoute: unknownRoute,
      ).page()
    ];
  }
}
