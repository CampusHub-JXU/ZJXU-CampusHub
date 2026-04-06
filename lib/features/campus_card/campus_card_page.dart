import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../shared/widgets/ship_card.dart';
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
  bool _obscured = false;

  @override
  Widget build(BuildContext context) {
    final service = CampusCardService.instance;
    final balance = service.cachedBalance;
    final lastUpdated = service.lastUpdated;

    return Scaffold(
      appBar: AppBar(title: const Text('校园卡')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildBalanceCard(context, balance, lastUpdated),
            const SizedBox(height: 16),
            _buildQuickActions(context),
            const SizedBox(height: 16),
            _buildRecentTransactions(context),
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard(
    BuildContext context,
    double? balance,
    DateTime? lastUpdated,
  ) {
    final balanceText = balance != null ? balance.toStringAsFixed(2) : '--';
    final timeText = lastUpdated != null
        ? '上次更新 ${lastUpdated.hour.toString().padLeft(2, '0')}:${lastUpdated.minute.toString().padLeft(2, '0')}'
        : '暂未获取余额';

    return ShipCard(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppColors.primary, AppColors.primaryDark],
      ),
      padding: const EdgeInsets.all(24),
      child: Stack(
        children: [
          // Watermark
          Positioned(
            right: -16,
            top: -16,
            child: Icon(
              Icons.credit_card,
              size: 100,
              color: Colors.white.withValues(alpha: 0.06),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.credit_card, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    '校园卡',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _obscured = !_obscured),
                    child: Icon(
                      _obscured ? Icons.visibility_off : Icons.visibility,
                      size: 20,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '¥ ',
                    style: TextStyle(
                      fontSize: 20,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                  Text(
                    _obscured ? '****' : balanceText,
                    style: const TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                timeText,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    return ShipCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _QuickAction(
            icon: Icons.qr_code_2,
            label: '付款码',
            color: AppColors.primary,
            onTap: () => context.pushNamed('campus-card-payment'),
          ),
          _QuickAction(
            icon: Icons.add_circle_outline,
            label: '充值',
            color: AppColors.success,
            onTap: () => _openCampusCardDetail(),
          ),
          _QuickAction(
            icon: Icons.receipt_long_outlined,
            label: '账单',
            color: AppColors.info,
            onTap: () => _openCampusCardDetail(),
          ),
          _QuickAction(
            icon: Icons.open_in_new,
            label: '详情',
            color: AppColors.gold,
            onTap: () => _openCampusCardDetail(),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentTransactions(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ShipCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history, size: 20, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                '最近交易',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Placeholder transactions
          _TransactionItem(
            icon: Icons.restaurant,
            title: '食堂消费',
            subtitle: '梁林校区第一食堂',
            amount: '-¥12.50',
            time: '今天 12:30',
            isExpense: true,
          ),
          const SizedBox(height: 12),
          _TransactionItem(
            icon: Icons.local_cafe,
            title: '超市消费',
            subtitle: '校园超市',
            amount: '-¥8.00',
            time: '今天 15:20',
            isExpense: true,
          ),
          const SizedBox(height: 12),
          _TransactionItem(
            icon: Icons.add_circle,
            title: '在线充值',
            subtitle: '支付宝',
            amount: '+¥100.00',
            time: '昨天 09:15',
            isExpense: false,
          ),
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
            if (bodyText) texts.push(bodyText);
            const frames = document.querySelectorAll('iframe');
            for (const frame of frames) {
              try {
                const frameText = frame.contentDocument?.body?.innerText;
                if (frameText) texts.push(frameText);
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
        if (balance != null) return balance;
      } catch (_) {
        continue;
      }
    }

    return null;
  }
}

// ── Quick Action Button ─────────────────────────────────────────────────────

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Transaction Item ────────────────────────────────────────────────────────

class _TransactionItem extends StatelessWidget {
  const _TransactionItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.time,
    required this.isExpense,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String amount;
  final String time;
  final bool isExpense;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isExpense ? AppColors.error : AppColors.success,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              amount,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isExpense ? cs.onSurface : AppColors.success,
              ),
            ),
            Text(
              time,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}
