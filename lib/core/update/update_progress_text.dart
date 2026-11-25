import 'apk_update_controller.dart';

/// 后台下载进度的紧凑文案（首页更新角标 tooltip / 设置页副标题共用）。
///
/// 与更新弹窗同一原则：只投影原生真实进度，已知总量才给百分比，
/// 未知总量只给已下载字节，**绝不**合成百分比或假进度。
String formatUpdateBytes(int bytes) {
  const kb = 1024;
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// 紧凑的一行后台下载状态；不适用（非下载 / 就绪类阶段）时返回 null。
///
/// 仅覆盖 `enqueued / downloading / paused / verifying` 与
/// `readyToInstall / permissionRequired`：前者给进度，后者是「已就绪」
/// 提示；其余阶段（失败 / 取消 / 空闲 / 安装器已打开 / 对账与清理）不由
/// 非阻塞入口重复表达，详情以弹窗为准。
String? describeManagedUpdateProgress(ApkUpdateState state) {
  final bytes = state.bytesDownloaded;
  final total = state.totalBytes;
  switch (state.phase) {
    case ApkUpdatePhase.enqueued:
      return '正在加入下载队列…';
    case ApkUpdatePhase.downloading:
    case ApkUpdatePhase.paused:
      final prefix = state.phase == ApkUpdatePhase.paused ? '下载已暂停' : '后台下载中';
      if (bytes != null && total != null && total > 0) {
        final percent = ((bytes / total) * 100).clamp(0, 100).round();
        return '$prefix $percent%';
      }
      if (bytes != null) {
        return '$prefix，已下载 ${formatUpdateBytes(bytes)}';
      }
      return '$prefix…';
    case ApkUpdatePhase.verifying:
      return '正在校验安装包…';
    case ApkUpdatePhase.readyToInstall:
    case ApkUpdatePhase.permissionRequired:
      return '更新已就绪，点击安装';
    case ApkUpdatePhase.idle:
    case ApkUpdatePhase.installerOpened:
    case ApkUpdatePhase.failed:
    case ApkUpdatePhase.canceled:
    case ApkUpdatePhase.unavailable:
    case ApkUpdatePhase.reconcileRequired:
    case ApkUpdatePhase.cleanupPending:
      return null;
  }
}
