enum SettingType {
  privacySetting('隐私设置'),
  recommendSetting('推荐流设置'),
  videoSetting('音视频设置'),
  playSetting('播放器设置'),
  styleSetting('外观设置'),
  layoutSetting('布局设置'),
  extraSetting('其它设置'),
  webdavSetting('WebDAV 设置'),
  desktopLyrics('桌面歌词'),
  about('关于'),
  ;

  final String title;
  const SettingType(this.title);
}
