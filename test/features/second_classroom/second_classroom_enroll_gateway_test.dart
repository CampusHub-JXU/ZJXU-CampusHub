import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_enroll_gateway.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
    // 内存 Cookie 存储仍会解析目录路径，测试环境没有 path_provider。
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async {
      final dir = await Directory.systemTemp.createTemp('sc_enroll_test_');
      return '${dir.path}/$folderName/';
    };
  });

  group('auto enroll switch', () {
    test('defaults to disabled', () async {
      expect(
        await SecondClassroomEnrollGateway.instance.isAutoEnrollEnabled(),
        isFalse,
      );
    });

    test('round trips through shared preferences', () async {
      final gateway = SecondClassroomEnrollGateway();
      await gateway.setAutoEnrollEnabled(true);
      expect(await gateway.isAutoEnrollEnabled(), isTrue);
      expect(
        await SecondClassroomEnrollGateway.instance.isAutoEnrollEnabled(),
        isTrue,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SecondClassroomEnrollGateway.autoEnrollKey), isTrue);

      await gateway.setAutoEnrollEnabled(false);
      expect(await gateway.isAutoEnrollEnabled(), isFalse);
      expect(
        prefs.getBool(SecondClassroomEnrollGateway.autoEnrollKey),
        isFalse,
      );
    });
  });

  group('submit', () {
    test('returns needsLogin when no account is verified', () async {
      final gateway = SecondClassroomEnrollGateway();
      final result = await gateway.submit(_activity);
      expect(result, SecondClassroomEnrollResult.needsLogin);
      expect(gateway.lastFailureReason, isNull);
    });

    test('clears the previous failure reason before running', () async {
      final gateway = SecondClassroomEnrollGateway()
        ..lastFailureReason = '上次失败';
      await gateway.submit(_activity);
      expect(gateway.lastFailureReason, isNull);
    });

    test(
      'returns needsLogin when the second classroom session fails',
      () async {
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: '20240001',
        );
        final gateway = SecondClassroomEnrollGateway();

        final result = await gateway.submit(_activity);

        // 测试环境无法建立第二课堂会话，必须停在 needsLogin 而不是写入报名缓存。
        expect(result, SecondClassroomEnrollResult.needsLogin);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getKeys().where(
            (key) => key.startsWith('second_classroom_enroll_v1_'),
          ),
          isEmpty,
        );
      },
    );

    test('rejects activities without a valid id', () async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20240001',
      );
      final gateway = SecondClassroomEnrollGateway();

      final result = await gateway.submit(_activity.copyWith(id: 0));

      expect(result, SecondClassroomEnrollResult.needsLogin);
    });
  });
}

final _activity = SecondClassroomActivity(
  id: 2485,
  title: '经院学子 开跑啦',
  coverId: 'cover-id',
  iconId: 'icon-id',
  registrationStartAt: DateTime(2026, 6, 9, 10),
  registrationEndAt: DateTime(2026, 6, 9, 14),
  activityStartAt: DateTime(2026, 6, 9, 16),
  activityEndAt: DateTime(2026, 6, 9, 17),
  creditHours: 0,
  location: '兴德楼北楼201',
  summary: '',
  contactName: '',
  contactPhone: '',
  categoryName: '思想成长',
  organizerName: '经济学院团委',
  capacity: 90,
  enrolledCount: 10,
  isRegistered: false,
  hasCheckedIn: false,
  hasRetaken: false,
);
