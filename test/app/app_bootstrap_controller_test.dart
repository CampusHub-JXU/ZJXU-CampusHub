import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/automatic_login.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';

import '../helpers/test_setup.dart';
import '../helpers/credential_store_test_ext.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // 控制器为单例：复位到 idle，避免跨用例串扰（同时清测试注入）。
    AppBootstrapController.instance.debugReset();
  });

  group('AppBootstrapController.navigationReady 派生信号', () {
    test('idle/warming 阶段为 false，localStateReady/completed 为 true', () {
      final controller = AppBootstrapController.instance;

      controller.debugReset();
      expect(controller.navigationReady.value, isFalse);

      controller.debugSetPhase(AppBootstrapPhase.warming);
      expect(controller.navigationReady.value, isFalse);

      controller.debugSetPhase(AppBootstrapPhase.localStateReady);
      expect(controller.navigationReady.value, isTrue);

      controller.debugSetPhase(AppBootstrapPhase.completed);
      expect(controller.navigationReady.value, isTrue);
    });

    test('回退到 warming 时信号同步翻回 false', () {
      final controller = AppBootstrapController.instance;

      controller.debugSetPhase(AppBootstrapPhase.completed);
      expect(controller.navigationReady.value, isTrue);

      controller.debugSetPhase(AppBootstrapPhase.warming);
      expect(controller.navigationReady.value, isFalse);
    });

    test('navigationReady 与 phase 变更同批通知监听者', () {
      final controller = AppBootstrapController.instance;
      final observed = <bool>[];
      void listener() => observed.add(controller.navigationReady.value);
      controller.navigationReady.addListener(listener);
      addTearDown(() => controller.navigationReady.removeListener(listener));

      controller.debugSetPhase(AppBootstrapPhase.localStateReady);
      expect(observed, [true]);
    });
  });

  group('AppBootstrapController.warmUpAfterFirstFrame 身份与缓存顺序', () {
    setUp(() async {
      // AppLogger.init 依赖 path_provider（暖启动会调用）。
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return Directory.systemTemp.path;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(pathProviderChannel, null),
      );
      await resetTestEnvironment();
      // 暖启动后的静默自动登录默认被替换为 no-op，避免测试触发真实登录链路。
      AppBootstrapController.instance.debugAutomaticLoginAttemptOverride = (
        domain, {
        String? expectedAccount,
      }) async => AutomaticLoginOutcome.notEligible;
    });

    const allSteps = <String>[
      AppBootstrapController.warmUpStepZhengfangAuth,
      AppBootstrapController.warmUpStepUnifiedAuth,
      AppBootstrapController.warmUpStepChangxingJiada,
      AppBootstrapController.warmUpStepDormElectricity,
      AppBootstrapController.warmUpStepSchedule,
      AppBootstrapController.warmUpStepCampusCard,
      AppBootstrapController.warmUpStepExam,
      AppBootstrapController.warmUpStepGrades,
    ];

    test('两域认证恢复完成后才恢复按账号隔离的缓存', () async {
      final controller = AppBootstrapController.instance;
      final events = <String>[];
      Future<void> record(String label) async {
        events.add('start:$label');
        await Future<void>.delayed(Duration.zero);
        events.add('end:$label');
      }

      for (final label in allSteps) {
        controller.debugWarmUpStepOverrides[label] = () => record(label);
      }

      await controller.warmUpAfterFirstFrame();

      final authEnds = <int>[
        events.indexOf('end:${AppBootstrapController.warmUpStepZhengfangAuth}'),
        events.indexOf('end:${AppBootstrapController.warmUpStepUnifiedAuth}'),
      ];
      expect(authEnds.every((index) => index >= 0), isTrue);
      final lastAuthEnd = authEnds.reduce((a, b) => a > b ? a : b);

      for (final label in const <String>[
        AppBootstrapController.warmUpStepCampusCard,
        AppBootstrapController.warmUpStepExam,
        AppBootstrapController.warmUpStepGrades,
      ]) {
        expect(
          events.indexOf('start:$label'),
          greaterThan(lastAuthEnd),
          reason: '$label 必须在两域认证恢复完成后才开始',
        );
      }

      // 非身份步骤与认证并行：在第一段认证结束前就已启动。
      expect(
        events.indexOf('start:${AppBootstrapController.warmUpStepSchedule}'),
        lessThan(lastAuthEnd),
      );
      expect(controller.phase.value, AppBootstrapPhase.completed);
    });

    test('某域恢复失败不会挂死暖启动', () async {
      final controller = AppBootstrapController.instance;
      var campusCardRan = false;
      controller.debugWarmUpStepOverrides[AppBootstrapController
          .warmUpStepZhengfangAuth] = () async {
        throw StateError('auth restore failed');
      };
      controller.debugWarmUpStepOverrides[AppBootstrapController
          .warmUpStepGrades] = () async {
        throw StateError('grades restore failed');
      };
      controller.debugWarmUpStepOverrides[AppBootstrapController
          .warmUpStepCampusCard] = () async {
        campusCardRan = true;
      };

      await controller.warmUpAfterFirstFrame();

      expect(controller.phase.value, AppBootstrapPhase.completed);
      expect(controller.navigationReady.value, isTrue);
      // 同批 / 后批步骤不被失败步骤阻断。
      expect(campusCardRan, isTrue);
    });

    test('先恢复身份再恢复 owner 缓存（真实服务）', () async {
      final now = DateTime.now();
      await CredentialStore.instance.saveZhengfangSession('2025000001');
      await CredentialStore.instance.saveUnifiedAuthSession('casuser');
      final academicEpoch = (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.academic,
      )).epoch;
      final unifiedEpoch = (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.unified,
      )).epoch;

      await SharedPreferencesPrivateCacheStore(GradesService.cacheKey).write(
        PrivateCacheEnvelope(
          owner: '2025000001',
          updatedAt: now,
          epoch: academicEpoch,
          payload: [
            {
              'kcmc': '高等数学',
              'cj': '92',
              'bfzcj': '92',
              'jd': '4.0',
              'xf': '4.5',
            },
          ],
        ),
      );
      await SharedPreferencesPrivateCacheStore(ExamService.cacheKey).write(
        PrivateCacheEnvelope(
          owner: '2025000001',
          updatedAt: now,
          epoch: academicEpoch,
          payload: [
            {
              'kcmc': '微观经济学',
              'kssj': '(2099-01-01) 09:00-11:00',
              'cdmc': '1教302',
              'cdxqmc': '梁林校区',
              'zwh': '12',
              'ksmc': '期末考试',
              'kkxy': '经济学院',
              'cxbj': '',
              'xnmc': '2026-2027',
              'xqmmc': '1',
            },
          ],
        ),
      );
      await SecureStoragePrivateCacheStore(CampusCardService.cacheKey).write(
        PrivateCacheEnvelope(
          owner: 'casuser',
          updatedAt: now,
          epoch: unifiedEpoch,
          payload: 38.2,
        ),
      );

      await AppBootstrapController.instance.warmUpAfterFirstFrame();

      expect(GradesService.instance.cachedGrades, isNotNull);
      expect(ExamService.instance.cachedExams, isNotNull);
      expect(CampusCardService.instance.cachedBalance, 38.2);
      expect(
        AppBootstrapController.instance.phase.value,
        AppBootstrapPhase.completed,
      );
    });

    test('没有存储身份时 owner 缓存不恢复', () async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      await prefs.setString(
        'grades_cached_data',
        jsonEncode([
          {'kcmc': '高等数学', 'cj': '92', 'bfzcj': '92', 'jd': '4.0', 'xf': '4.5'},
        ]),
      );
      await prefs.setInt('grades_cached_at', now);
      await prefs.setString('grades_cached_owner', '2025000001');
      await prefs.setString(
        'exam_cached_data',
        jsonEncode([
          {
            'kcmc': '微观经济学',
            'kssj': '(2099-01-01) 09:00-11:00',
            'cdmc': '1教302',
            'cdxqmc': '梁林校区',
            'zwh': '12',
            'ksmc': '期末考试',
            'kkxy': '经济学院',
            'cxbj': '',
            'xnmc': '2026-2027',
            'xqmmc': '1',
          },
        ]),
      );
      await prefs.setInt('exam_cached_at', now);
      await prefs.setString('exam_cached_owner', '2025000001');

      await AppBootstrapController.instance.warmUpAfterFirstFrame();

      expect(GradesService.instance.cachedGrades, isNull);
      expect(ExamService.instance.cachedExams, isNull);
      expect(CampusCardService.instance.cachedBalance, isNull);
    });

    test('暖启动后对未登录域发起一次静默自动登录（不阻塞、不重复）', () async {
      final controller = AppBootstrapController.instance;
      for (final label in allSteps) {
        controller.debugWarmUpStepOverrides[label] = () async {};
      }
      // 教务已登录：不得再对它发起自动登录；CAS 未登录：应发起一次。
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '2025000001',
      );
      final attempted = <AuthRecoveryDomain>[];
      controller.debugAutomaticLoginAttemptOverride =
          (domain, {String? expectedAccount}) async {
            attempted.add(domain);
            return AutomaticLoginOutcome.notEligible;
          };

      await controller.warmUpAfterFirstFrame();
      await Future<void>.delayed(Duration.zero);

      expect(attempted, <AuthRecoveryDomain>[AuthRecoveryDomain.cas]);
      expect(controller.phase.value, AppBootstrapPhase.completed);
    });
  });
}
