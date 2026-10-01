import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/main.dart';
import 'package:PiliPlus/models/common/webview_menu_type.dart';
import 'package:PiliPlus/pages/tabhost/tab_controller.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class WebviewPage extends StatefulWidget {
  const WebviewPage({
    super.key,
    this.url,
    this.oid,
    this.title,
    this.userAgent,
    this.tabId,
  });

  final String? url;

  // note
  final int? oid;
  final String? title;
  final String? userAgent;

  /// 所在标签页的 id（非空 = 本页面在标签页中打开）：
  /// 此时不经路由，返回语义是"关闭当前标签"而非 Get.back()。
  final String? tabId;

  @override
  State<WebviewPage> createState() => _WebviewPageState();
}

class _WebviewPageState extends State<WebviewPage> {
  late final String _url = widget.url ?? Get.parameters['url'] ?? '';
  late final String userAgent;

  /// 是否在标签页中打开
  bool get _isTab => widget.tabId != null;
  final RxString title = ''.obs;
  final RxDouble progress = 1.0.obs;
  bool _inApp = false;
  bool _off = false;

  InAppWebViewController? _webViewController;

  static final _prefixRegex = RegExp(
    r'^(?!(https?://))\S+://',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    if (widget.userAgent != null) {
      userAgent = widget.userAgent!;
    } else if (widget.url != null) {
      // 标签页模式：不经路由，用平台默认 UA
      userAgent = BrowserUa.platform;
    } else {
      userAgent = switch (Get.parameters['uaType']) {
        'pc' => BrowserUa.pc,
        'mob' => BrowserUa.mob,
        _ => BrowserUa.platform,
      };
    }
    // 只有路由模式（widget.url == null）才读路由参数与 arguments：
    // 标签页模式下 Get.arguments 可能残留上一条路由的值。
    if (widget.url == null) {
      if (Get.arguments case final Map map) {
        _inApp = map['inApp'] ?? false;
        _off = map['off'] ?? false;
      }
    }
  }

  @override
  void dispose() {
    _webViewController = null;
    super.dispose();
  }

  /// 统一的"返回"语义：标签页中 = 关闭当前标签；路由中 = Get.back()。
  void _close() {
    if (_isTab) {
      final tabHost = TabHostController.instance;
      final idx = tabHost?.tabs.indexWhere((t) => t.id == widget.tabId) ?? -1;
      if (tabHost != null && idx >= 0) {
        tabHost.close(idx);
        return;
      }
    }
    Get.back();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isLinux) {
      return Scaffold(
        appBar: AppBar(),
        resizeToAvoidBottomInset: false,
        body: Center(
          child: TextButton(
            onPressed: () => PageUtils.launchURL(_url),
            child: const Text('unsupported'),
          ),
        ),
      );
    }
    return Scaffold(
      // 标签页模式下也显示工具栏（标题/刷新/复制链接/浏览器打开/清缓存）
      appBar: widget.url != null && !_isTab
          ? null
          : AppBar(
              // 标签页模式：手机竖屏不显示标签栏，给一个显式的关闭按钮
              leading: _isTab
                  ? IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _close,
                    )
                  : null,
              title: Obx(
                () => Text(
                  title.value.isNotEmpty ? title.value : _url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              bottom: PreferredSize(
                preferredSize: Size.zero,
                child: Obx(
                  () => progress.value < 1
                      ? LinearProgressIndicator(value: progress.value)
                      : const SizedBox.shrink(),
                ),
              ),
              actions: [
                PopupMenuButton(
                  onSelected: (item) async {
                    switch (item) {
                      case WebviewMenuItem.refresh:
                        _webViewController?.reload();
                        break;
                      case WebviewMenuItem.copy:
                        WebUri? uri = await _webViewController?.getUrl();
                        if (uri != null) {
                          Utils.copyText(uri.toString());
                        }
                        break;
                      case WebviewMenuItem.openInBrowser:
                        WebUri? uri = await _webViewController?.getUrl();
                        if (uri != null) {
                          PageUtils.launchURL(uri.toString());
                        }
                        break;
                      case WebviewMenuItem.clearCache:
                        try {
                          await InAppWebViewController.clearAllCache();
                          await _webViewController?.clearHistory();
                          SmartDialog.showToast('已清理');
                        } catch (e) {
                          SmartDialog.showToast(e.toString());
                        }
                        break;
                      case WebviewMenuItem.goBack:
                        if (await _webViewController?.canGoBack() == true) {
                          _webViewController?.goBack();
                        } else {
                          _close();
                        }
                        break;
                      case WebviewMenuItem.resetCookie:
                        await LoginUtils.setWebCookie();
                        SmartDialog.showToast('设置成功，刷新或重新打开网页');
                        break;
                    }
                  },
                  itemBuilder: (context) => <PopupMenuEntry<WebviewMenuItem>>[
                    ...WebviewMenuItem.values
                        .take(WebviewMenuItem.values.length - 1)
                        .map(
                          (item) => PopupMenuItem(
                            value: item,
                            child: Text(item.title),
                          ),
                        ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: WebviewMenuItem.goBack,
                      child: Text(
                        WebviewMenuItem.goBack.title,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
      body: SafeArea(
        child: InAppWebView(
          webViewEnvironment: webViewEnvironment,
          initialSettings: InAppWebViewSettings(
            clearCache: true,
            javaScriptEnabled: true,
            forceDark: ForceDark.AUTO,
            useHybridComposition: false,
            algorithmicDarkeningAllowed: true,
            useShouldOverrideUrlLoading: true,
            userAgent: userAgent,
            mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          ),
          initialUrlRequest: URLRequest(
            url: WebUri.uri(Uri.tryParse(_url) ?? Uri()),
          ),
          onWebViewCreated: (InAppWebViewController controller) {
            _webViewController = controller;
            controller
              ..addJavaScriptHandler(
                handlerName: 'finishButtonClicked',
                callback: (args) {
                  _close();
                },
              )
              ..addJavaScriptHandler(
                handlerName: 'infoBarClicked',
                callback: (args) async {
                  WebUri? uri = await controller.getUrl();
                  if (uri != null) {
                    String? oid = uri.queryParameters['oid'];
                    if (oid != null) {
                      PiliScheme.videoPush(int.parse(oid), null);
                    }
                  }
                },
              );
          },
          onProgressChanged: (controller, progress) {
            this.progress.value = progress / 100;
          },
          onTitleChanged: (controller, title) {
            this.title.value = title ?? '';
            // 标签页：标签标题跟随网页标题
            if (_isTab && title != null && title.isNotEmpty) {
              TabHostController.instance?.updateTabTitle(widget.tabId!, title);
            }
          },
          onCloseWindow: (controller) => _close(),
          onLoadStop: (controller, uri) {
            final url = uri.toString();
            if (url.startsWith('https://www.bilibili.com/h5/note-app')) {
              controller
                ..evaluateJavascript(
                  source: """
  document.querySelector('.finish-btn').addEventListener('click', function() {
      window.flutter_inappwebview.callHandler('finishButtonClicked');
  });
""",
                )
                ..evaluateJavascript(
                  source: """
  document.querySelector('.info-bar').addEventListener('click', function() {
      window.flutter_inappwebview.callHandler('infoBarClicked');
  });
""",
                );
            } else if (url.startsWith('https://live.bilibili.com')) {
              controller.evaluateJavascript(
                source: '''
                  document.styleSheets[0].insertRule('div.open-app-btn.bili-btn-warp {display:none;}', 0);
                  document.styleSheets[0].insertRule('#app__display-area > div.control-panel {display:none;}', 0);
                  ''',
              );
            }
            // _webViewController?.evaluateJavascript(
            //   source: '''
            //     document.querySelector('#internationalHeader').remove();
            //     document.querySelector('#message-navbar').remove();
            //   ''',
            // );
          },
          onDownloadStartRequest: Platform.isAndroid
              ? (controller, request) {
                  showDialog(
                    context: context,
                    builder: (context) {
                      String suggestedFilename = request.suggestedFilename
                          .toString();
                      String fileSize = CacheManager.formatSize(
                        request.contentLength.toDouble(),
                      );
                      try {
                        suggestedFilename = Uri.decodeComponent(
                          suggestedFilename,
                        );
                      } catch (e) {
                        if (kDebugMode) debugPrint(e.toString());
                      }
                      return AlertDialog(
                        title: Text(
                          '下载文件: $suggestedFilename ?',
                          style: const TextStyle(fontSize: 18),
                        ),
                        content: SelectableText(request.url.toString()),
                        actions: [
                          TextButton(
                            onPressed: Get.back,
                            child: Text(
                              '取消',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Get.back();
                              PageUtils.launchURL(request.url.toString());
                            },
                            child: Text('确定 ($fileSize)'),
                          ),
                        ],
                      );
                    },
                  );
                  progress.value = 1;
                }
              : null,
          shouldInterceptAjaxRequest: (controller, ajaxRequest) async {
            String url = ajaxRequest.url.toString();
            if (url.startsWith('//api.bilibili.com/x/note/add') &&
                widget.title != null) {
              return ajaxRequest
                ..data = ajaxRequest.data.toString().replaceFirst(
                  '&title=--&',
                  '&title=${widget.title}&',
                );
            }
            return null;
          },
          shouldInterceptRequest: (controller, request) async {
            String url = request.url.toString();
            if (url.startsWith(
              'https://passport.bilibili.com/x/passport-login/web',
            )) {
              progress.value = 1;
              return WebResourceResponse();
            }
            return null;
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            if (_inApp) {
              return NavigationActionPolicy.ALLOW;
            }
            late String url = navigationAction.request.url.toString();
            bool hasMatch = await PiliScheme.routePush(
              navigationAction.request.url?.uriValue ?? Uri(),
              selfHandle: true,
              off: _off,
            );
            // if (kDebugMode) debugPrint('webview: [$url], [$hasMatch]');
            if (hasMatch) {
              progress.value = 1;
              return NavigationActionPolicy.CANCEL;
            } else if (_prefixRegex.hasMatch(url)) {
              if (context.mounted) {
                SnackBar snackBar = SnackBar(
                  content: const Text('当前网页将要打开外部链接，是否打开'),
                  showCloseIcon: true,
                  persist: false,
                  action: SnackBarAction(
                    label: '打开',
                    onPressed: () => PageUtils.launchURL(url),
                  ),
                );
                ScaffoldMessenger.of(context).showSnackBar(snackBar);
              }
              progress.value = 1;
              return NavigationActionPolicy.CANCEL;
            }

            return NavigationActionPolicy.ALLOW;
          },
        ),
      ),
    );
  }
}
