import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/webview_page.dart';
import 'campus_card_service.dart';

class CampusCardPage extends StatefulWidget {
  const CampusCardPage({super.key});

  @override
  State<CampusCardPage> createState() => _CampusCardPageState();
}

class _CampusCardPageState extends State<CampusCardPage> {
  static const _serviceHallHost = 'mobilehall.zjxu.edu.cn';
  static const _statusPathKeyword = '/decision/view/form';

  bool _capturedInCurrentDetailPage = false;

  @override
  Widget build(BuildContext context) {
    final service = CampusCardService.instance;
    final balance = service.formatBalance(service.cachedBalance);
    final lastUpdated = service.lastUpdated;

    return Scaffold(
      appBar: AppBar(title: const Text('校园卡')),
      body: Column(
        children: [
          _buildBalanceHeader(context, balance, lastUpdated),
          const SizedBox(height: 24),
          _buildActions(context),
        ],
      ),
    );
  }

  Future<void> _openCampusCardDetail() async {
    _capturedInCurrentDetailPage = false;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebViewPage(
          title: '校园卡详情',
          url: CampusCardService.statusPageUrl,
          onLoadStop: _captureBalanceFromDetailPage,
        ),
      ),
    );

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _captureBalanceFromDetailPage(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    if (_capturedInCurrentDetailPage) return;

    final uri = Uri.tryParse(currentUrl);
    final path = uri?.path.toLowerCase();
    if (uri == null ||
        uri.host.toLowerCase() != _serviceHallHost ||
        path == null ||
        !path.contains(_statusPathKeyword)) {
      return;
    }

    final balance = await _extractBalanceWithRetry(controller);
    if (balance == null) return;

    CampusCardService.instance.updateCachedBalance(balance);
    _capturedInCurrentDetailPage = true;

    if (!mounted) return;
    setState(() {});
  }

  Future<double?> _extractBalanceWithRetry(
    InAppWebViewController controller,
  ) async {
    const delaysInMs = [0, 700, 1400, 2200];

    for (final delayInMs in delaysInMs) {
      if (delayInMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayInMs));
      }

      try {
        final rawText = await controller.evaluateJavascript(
          source: '''
            (() => {
              const texts = [];
              const bodyText = document.body?.innerText;
              if (bodyText) {
                texts.push(bodyText);
              }

              const frames = document.querySelectorAll('iframe');
              for (const frame of frames) {
                try {
                  const frameText = frame.contentDocument?.body?.innerText;
                  if (frameText) {
                    texts.push(frameText);
                  }
                } catch (_) {}
              }

              return texts.join('\\n');
            })();
          ''',
        );

        final text = rawText is String ? rawText : '${rawText ?? ''}';
        final balance = CampusCardService.instance.parseBalanceFromPageText(
          text,
        );
        if (balance != null) {
          return balance;
        }
      } catch (_) {
        continue;
      }
    }

    return null;
  }

  Widget _buildBalanceHeader(
    BuildContext context,
    String balance,
    DateTime? lastUpdated,
  ) {
    final timeText = lastUpdated != null
        ? '上次更新: ${lastUpdated.hour.toString().padLeft(2, '0')}:${lastUpdated.minute.toString().padLeft(2, '0')}'
        : '暂未获取余额';

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
          child: Column(
            children: [
              const Icon(Icons.payment, size: 48, color: Colors.white70),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text(
                    '¥ ',
                    style: TextStyle(
                      fontSize: 24,
                      color: Colors.white70,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  Text(
                    balance,
                    style: const TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                timeText,
                style: const TextStyle(fontSize: 13, color: Colors.white60),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () => context.pushNamed('campus-card-payment'),
              icon: const Icon(Icons.qr_code_2),
              label: const Text('消费码'),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () {
                _openCampusCardDetail();
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('查看详情'),
            ),
          ),
        ],
      ),
    );
  }
}
