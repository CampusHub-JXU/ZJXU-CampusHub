import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import 'update_model.dart';
import 'update_service.dart';
import 'update_source.dart';

enum UpdateCheckStatus { disabled, updateAvailable, upToDate, error, checking }

class UpdateCheckResult {
  const UpdateCheckResult(this.status, {this.release});

  final UpdateCheckStatus status;
  final AppRelease? release;
}

class UpdateChecker {
  UpdateChecker._();

  static final UpdateChecker instance = UpdateChecker._();

  final ValueNotifier<AppRelease?> availableRelease =
      ValueNotifier<AppRelease?>(null);
  final ValueNotifier<bool> isChecking = ValueNotifier<bool>(false);

  bool get isUpdateEnabled => UpdateService.instance.isRemoteUpdateEnabled;

  Future<UpdateCheckResult> check({bool silent = false}) async {
    if (!isUpdateEnabled) {
      availableRelease.value = null;
      return const UpdateCheckResult(UpdateCheckStatus.disabled);
    }

    if (isChecking.value) {
      return const UpdateCheckResult(UpdateCheckStatus.checking);
    }

    isChecking.value = true;
    try {
      final release = await UpdateService.instance.checkForUpdate();
      availableRelease.value = release;
      if (release == null) {
        return const UpdateCheckResult(UpdateCheckStatus.upToDate);
      }
      return UpdateCheckResult(
        UpdateCheckStatus.updateAvailable,
        release: release,
      );
    } on UpdateSourceUnavailableException catch (error) {
      AppLogger.instance.network(LogLevel.debug, '更新源暂不可用: $error');
      return const UpdateCheckResult(UpdateCheckStatus.error);
    } catch (error) {
      AppLogger.instance.network(LogLevel.warn, '更新检查异常: $error');
      return const UpdateCheckResult(UpdateCheckStatus.error);
    } finally {
      isChecking.value = false;
    }
  }

  @visibleForTesting
  void debugReset() {
    availableRelease.value = null;
    isChecking.value = false;
  }
}
