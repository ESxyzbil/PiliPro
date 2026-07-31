import 'package:flutter/widgets.dart';
import 'package:get/get_core/src/log.dart';
import 'package:get/get_core/src/smart_management.dart';

/// GetInterface allows any auxiliary package to be merged into the "Get"
/// class through extensions
abstract class GetInterface {
  SmartManagement smartManagement = SmartManagement.full;
  RouterDelegate? routerDelegate;
  RouteInformationParser? routeInformationParser;
  LogWriterCallback log = defaultLogWriterCallback;
}
