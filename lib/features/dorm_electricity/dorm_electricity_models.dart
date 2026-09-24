/// 宿舍电费（epay100 电控）的 DTO 与异常类型。
///
/// 从 `dorm_electricity_service.dart` 拆出（文件长度约束，行为不变）；
/// service 文件继续 `export` 本文件，历史 `import .../dorm_electricity_service.dart`
/// 的调用方无需改动。
library;

/// 宿舍电费服务异常：携带可直接展示给用户的 [message]。
class DormServiceException implements Exception {
  final String message;

  const DormServiceException(this.message);

  @override
  String toString() => message;
}

/// 园区（校区）——epay100 电控体系第一级。
class DormArea {
  final String id;
  final String name;

  const DormArea({required this.id, required this.name});
}

/// 楼幢——第二级，隶属园区。
class DormBuilding {
  final String areaId;
  final String areaName;
  final String buildingId;
  final String buildingName;

  const DormBuilding({
    required this.areaId,
    required this.areaName,
    required this.buildingId,
    required this.buildingName,
  });
}

/// 楼层——第三级（多数楼幢只有一个「默认楼层」）。
class DormFloor {
  final String areaId;
  final String buildingId;
  final String floorId;
  final String floorName;

  const DormFloor({
    required this.areaId,
    required this.buildingId,
    required this.floorId,
    required this.floorName,
  });
}

/// 房间——第四级。
class DormRoom {
  final String areaId;
  final String buildingId;
  final String floorId;
  final String roomId;
  final String floorName;
  final String roomName;

  const DormRoom({
    required this.areaId,
    required this.buildingId,
    required this.floorId,
    required this.roomId,
    required this.floorName,
    required this.roomName,
  });
}

/// 已保存的寝室配置（epay100 电控四级 id）。
class DormRoomConfig {
  final String areaId;
  final String buildingId;
  final String floorId;
  final String roomId;

  const DormRoomConfig({
    required this.areaId,
    required this.buildingId,
    required this.floorId,
    required this.roomId,
  });
}
