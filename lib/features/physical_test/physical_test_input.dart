double? parsePhysicalTestNumber(String input) {
  final value = double.tryParse(input);
  return value != null && value.isFinite ? value : null;
}

double? parsePhysicalTestPositiveNumber(String input) {
  final value = parsePhysicalTestNumber(input);
  return value != null && value > 0 ? value : null;
}

double? parsePhysicalTestNonNegativeNumber(String input) {
  final value = parsePhysicalTestNumber(input);
  return value != null && value >= 0 ? value : null;
}

int? parsePhysicalTestRepetitions(String input) {
  final count = int.tryParse(input, radix: 10);
  return count != null && count >= 0 ? count : null;
}

double? parsePhysicalTestEndurance(String input) {
  final time = input.length == 1 ? '$input.00' : input;
  final match = RegExp(r'^(\d+)\.([0-5]\d)$').firstMatch(time);
  if (match == null) return null;

  final minutes = int.tryParse(match[1]!);
  if (minutes == null) return null;
  final total = minutes * 60.0 + int.parse(match[2]!);
  return total > 0 ? total : null;
}
