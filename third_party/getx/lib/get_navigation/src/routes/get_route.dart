// ignore_for_file: overridden_fields
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/get_instance.dart';
import 'package:get/get_navigation/get_navigation.dart';

class GetPage<T> extends Page<T> {
  final GetPageBuilder page;
  final Map<String, String>? parameters;
  final String? title;
  final bool? participatesInRootNavigator;
  final bool maintainState;
  final Bindings? binding;
  final List<Bindings> bindings;
  final bool preventDuplicates;

  // @override
  // final LocalKey? key;

  // @override
  // RouteSettings get settings => this;

  @override
  final Object? arguments;

  @override
  final String name;

  final List<GetPage> children;
  final List<GetMiddleware>? middlewares;
  final PathDecoded path;
  final GetPage? unknownRoute;

  GetPage({
    required this.name,
    required this.page,
    this.title,
    this.participatesInRootNavigator,
    this.maintainState = true,
    this.parameters,
    this.binding,
    this.bindings = const [],
    this.children = const <GetPage>[],
    this.middlewares,
    this.unknownRoute,
    this.arguments,
    this.preventDuplicates = true,
  })  : path = _nameToRegex(name),
        assert(name.startsWith('/'),
            'It is necessary to start route name [$name] with a slash: /$name'),
        super(
          key: ValueKey(name),
          name: name,
          arguments: Get.arguments,
        );

  // settings = RouteSettings(name: name, arguments: Get.arguments);

  GetPage<T> copy({
    String? name,
    GetPageBuilder? page,
    Map<String, String>? parameters,
    String? title,
    bool? maintainState,
    Bindings? binding,
    List<Bindings>? bindings,
    RouteSettings? settings,
    List<GetPage>? children,
    GetPage? unknownRoute,
    List<GetMiddleware>? middlewares,
    bool? preventDuplicates,
    bool? participatesInRootNavigator,
    Object? arguments,
  }) {
    return GetPage(
      participatesInRootNavigator:
          participatesInRootNavigator ?? this.participatesInRootNavigator,
      preventDuplicates: preventDuplicates ?? this.preventDuplicates,
      name: name ?? this.name,
      page: page ?? this.page,
      parameters: parameters ?? this.parameters,
      title: title ?? this.title,
      maintainState: maintainState ?? this.maintainState,
      binding: binding ?? this.binding,
      bindings: bindings ?? this.bindings,
      children: children ?? this.children,
      unknownRoute: unknownRoute ?? this.unknownRoute,
      middlewares: middlewares ?? this.middlewares,
      arguments: arguments ?? this.arguments,
    );
  }

  @override
  Route<T> createRoute(BuildContext context) {
    // return GetPageRoute<T>(settings: this, page: page);
    final page = PageRedirect(
      route: this,
      settings: this,
      unknownRoute: unknownRoute,
    ).getPageToRoute<T>(this, unknownRoute);

    return page;
  }

  static PathDecoded _nameToRegex(String path) {
    var keys = <String?>[];

    String replace(Match pattern) {
      var buffer = StringBuffer('(?:');

      if (pattern[1] != null) buffer.write('.');
      buffer.write('([\\w%+-._~!\$&\'()*,;=:@]+))');
      if (pattern[3] != null) buffer.write('?');

      keys.add(pattern[2]);
      return "$buffer";
    }

    var stringPath = '$path/?'
        .replaceAllMapped(RegExp(r'(\.)?:(\w+)(\?)?'), replace)
        .replaceAll('//', '/');

    return PathDecoded(RegExp('^$stringPath\$'), keys);
  }
}

@immutable
class PathDecoded {
  final RegExp regex;
  final List<String?> keys;

  const PathDecoded(this.regex, this.keys);

  @override
  int get hashCode => regex.hashCode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PathDecoded &&
        other.regex == regex; // && listEquals(other.keys, keys);
  }
}
