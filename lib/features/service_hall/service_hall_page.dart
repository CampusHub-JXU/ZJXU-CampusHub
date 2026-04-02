import 'package:flutter/material.dart';

class ServiceHallPage extends StatelessWidget {
  const ServiceHallPage({super.key});

  static const _services = [
    _ServiceItem('图书馆', Icons.local_library, Color(0xFF1565C0)),
    _ServiceItem('校医院', Icons.local_hospital, Color(0xFF2E7D32)),
    _ServiceItem('一卡通', Icons.credit_card, Color(0xFF6A1B9A)),
    _ServiceItem('教务系统', Icons.school, Color(0xFFE65100)),
    _ServiceItem('网络中心', Icons.wifi, Color(0xFF00838F)),
    _ServiceItem('后勤服务', Icons.build, Color(0xFF4E342E)),
  ];

  void _showComingSoon(BuildContext context) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('功能开发中')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务大厅')),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: TextField(
                readOnly: true,
                onTap: () {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('搜索功能开发中')));
                },
                decoration: InputDecoration(
                  hintText: '搜索服务...',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  filled: true,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                '常用服务',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              childAspectRatio: 1.0,
              children: [
                for (final service in _services)
                  Card(
                    child: InkWell(
                      onTap: () => _showComingSoon(context),
                      borderRadius: BorderRadius.circular(12),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircleAvatar(
                            backgroundColor: service.color.withValues(
                              alpha: 0.15,
                            ),
                            child: Icon(service.icon, color: service.color),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            service.name,
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _ServiceItem {
  const _ServiceItem(this.name, this.icon, this.color);

  final String name;
  final IconData icon;
  final Color color;
}
