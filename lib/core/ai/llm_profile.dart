enum LlmProviderPreset {
  deepseek(
    defaultBaseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
    commonModels: ['deepseek-chat', 'deepseek-reasoner'],
  ),
  openaiCompatible(defaultBaseUrl: '', defaultModel: '', commonModels: []);

  const LlmProviderPreset({
    required this.defaultBaseUrl,
    required this.defaultModel,
    required this.commonModels,
  });

  final String defaultBaseUrl;
  final String defaultModel;
  final List<String> commonModels;
}

class LlmProfile {
  const LlmProfile({
    required this.id,
    required this.name,
    required this.preset,
    required this.baseUrl,
    required this.model,
    this.temperature = 0.7,
    this.maxTokens,
  });

  final String id;
  final String name;
  final LlmProviderPreset preset;
  final String baseUrl;
  final String model;
  final double temperature;
  final int? maxTokens;

  LlmProfile copyWith({
    String? id,
    String? name,
    LlmProviderPreset? preset,
    String? baseUrl,
    String? model,
    double? temperature,
    int? maxTokens,
    bool clearMaxTokens = false,
  }) {
    return LlmProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      preset: preset ?? this.preset,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
      maxTokens: clearMaxTokens ? null : (maxTokens ?? this.maxTokens),
    );
  }

  factory LlmProfile.fromJson(Map<String, dynamic> json) => LlmProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    preset: LlmProviderPreset.values.byName(json['preset'] as String),
    baseUrl: json['baseUrl'] as String,
    model: json['model'] as String,
    temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
    maxTokens: json['maxTokens'] as int?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'preset': preset.name,
    'baseUrl': baseUrl,
    'model': model,
    'temperature': temperature,
    'maxTokens': maxTokens,
  };
}
