import 'dart:ffi';
import 'dart:io';

final _kernel32 = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;
final _outputDebugString = _kernel32?.lookupFunction<
    Void Function(Pointer<Utf16>),
    void Function(Pointer<Utf16>)>('OutputDebugStringW');

void outputDebug(String message) {
  if (_outputDebugString == null) return;
  final pointer = message.toNativeUtf16();
  _outputDebugString(pointer);
  calloc.free(pointer);
}
