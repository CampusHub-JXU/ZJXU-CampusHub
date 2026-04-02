import 'package:flutter/material.dart';

class CampusCardPage extends StatefulWidget {
  const CampusCardPage({super.key});

  @override
  State<CampusCardPage> createState() => _CampusCardPageState();
}

class _CampusCardPageState extends State<CampusCardPage> {
  static const _actions = [
    _CardAction(label: '充值', icon: Icons.add_card),
    _CardAction(label: '消费记录', icon: Icons.receipt_long),
    _CardAction(label: '挂失', icon: Icons.lock),
    _CardAction(label: '解挂', icon: Icons.lock_open),
  ];

  static const _records = [
    _RecordItem(
      title: '食堂消费',
      time: '今日 12:30',
      amount: '-¥8.50',
      icon: Icons.restaurant,
    ),
    _RecordItem(
      title: '图书馆打印',
      time: '昨日 09:15',
      amount: '-¥2.00',
      icon: Icons.print,
    ),
    _RecordItem(
      title: '超市购物',
      time: '前日 18:45',
      amount: '-¥23.60',
      icon: Icons.store,
    ),
  ];

  void _showComingSoon() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('功能开发中')));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('校园卡'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _showComingSoon,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Text(
                      '嘉兴大学校园卡',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Spacer(),
                    Icon(Icons.school, color: Colors.white),
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  '¥ --',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '账户余额',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                ),
                const SizedBox(height: 24),
                const Row(
                  children: [
                    Text(
                      '**** **** **** 1234',
                      style: TextStyle(color: Colors.white),
                    ),
                    Spacer(),
                    Text('持卡人 --', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (int i = 0; i < _actions.length; i++) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _showComingSoon,
                      icon: Icon(_actions[i].icon, size: 18),
                      label: Text(_actions[i].label),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  if (i != _actions.length - 1) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '最近消费记录',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _records.length,
              itemBuilder: (context, index) {
                final record = _records[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: colorScheme.primaryContainer,
                    child: Icon(record.icon, color: colorScheme.primary),
                  ),
                  title: Text(record.title),
                  subtitle: Text(record.time),
                  trailing: Text(
                    record.amount,
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CardAction {
  const _CardAction({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

class _RecordItem {
  const _RecordItem({
    required this.title,
    required this.time,
    required this.amount,
    required this.icon,
  });

  final String title;
  final String time;
  final String amount;
  final IconData icon;
}
