import 'package:flutter/material.dart';

import '../../shared/widgets/unified_auth_login_widget.dart';

class UnifiedAuthLoginPage extends StatelessWidget {
  const UnifiedAuthLoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('一卡通登录')),
      body: UnifiedAuthLoginWidget(
        title: '登录一卡通',
        description: '账号为校园一卡通号',
        onLoginSuccess: () => Navigator.of(context).pop(true),
      ),
    );
  }
}
