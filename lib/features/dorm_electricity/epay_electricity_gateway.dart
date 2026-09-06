/// 兼容导出：epay100 网关已下沉到 `core/epay100/` 供校园卡付款码等复用，
/// 电费相关调用方继续经本文件（或直接 import core）使用。
library;

import '../../core/epay100/epay100_gateway.dart';

export '../../core/epay100/epay100_gateway.dart';

/// 旧名称兼容别名（dorm_electricity 历史调用方与测试仍在使用）。
typedef EpayElectricityGateway = Epay100Gateway;
typedef HeadlessEpayElectricityGateway = HeadlessEpay100Gateway;
