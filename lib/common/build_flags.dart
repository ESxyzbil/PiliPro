/// 编译开关（--dart-define）
/// 默认关闭：OCR/ASR 功能未调好时不编入/不显示。
/// 开启：flutter build apk --release --dart-define=ENABLE_OCR=true --dart-define=ENABLE_ASR=true
const bool kEnableOcr = bool.fromEnvironment('ENABLE_OCR', defaultValue: false);
const bool kEnableAsr = bool.fromEnvironment('ENABLE_ASR', defaultValue: false);
