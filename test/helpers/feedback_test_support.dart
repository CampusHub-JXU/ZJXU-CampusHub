import 'package:jxu_campus_hub/features/settings/feedback_service.dart';
import 'package:jxu_campus_hub/features/settings/feedback_store.dart';

class MemoryFeedbackStore extends FeedbackStore {
  final preferences = <String, String>{};
  final records = <Map<String, Object?>>[];
  bool failWrites = false;

  @override
  Future<String?> preference(String key) async => preferences[key];
  @override
  Future<void> setPreference(String key, String? value) async {
    if (failWrites) throw StateError('disk unavailable');
    if (value == null) {
      preferences.remove(key);
    } else {
      preferences[key] = value;
    }
  }

  @override
  Future<void> recordSubmission(
    String title,
    FeedbackSubmitResult result,
  ) async {
    if (failWrites) throw StateError('disk unavailable');
    records.add({
      'title': title,
      'number': result.issueNumber,
      'url': result.issueUrl,
    });
    preferences.remove('draft');
  }

  @override
  Future<List<Map<String, Object?>>> submissions() async => records;
}
