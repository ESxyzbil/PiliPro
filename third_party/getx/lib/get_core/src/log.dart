import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show kDebugMode;

///VoidCallback from logs
typedef LogWriterCallback = void Function(String text, {bool isError});

/// default logger from GetX
void defaultLogWriterCallback(String value, {bool isError = false}) {
  if (kDebugMode || isError) developer.log(value, name: 'GETX');
}
