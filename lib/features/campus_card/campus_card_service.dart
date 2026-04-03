class CampusCardService {
  CampusCardService._();

  static final CampusCardService instance = CampusCardService._();

  double? _cachedBalance;

  double? get cachedBalance => _cachedBalance;

  static const statusPageUrl =
      'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5&viewlet=xxkj%252Fmobile%252Fykt.frm#/form';

  static const paymentCodeEntryUrl =
      'https://app.xiaoyuan.ccb.com/EMTSTATIC/DZK2026032101/index2026032101.html#/cardmentkey';

  void updateCachedBalance(double? balance) {
    if (balance == null) return;
    _cachedBalance = balance;
  }

  double? parseBalanceFromPageText(String rawText) {
    final text = rawText
        .replaceAll('\u00A0', ' ')
        .replaceAll('\u3000', ' ')
        .trim();
    if (text.isEmpty) return null;

    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && line != '|')
        .toList();

    String normalize(String value) => value.replaceAll(RegExp(r'\s+'), '');

    double? parseAmount(String value) {
      final match = RegExp(r'([0-9]+(?:\.[0-9]+)?)\s*元?').firstMatch(value);
      if (match == null) return null;
      return double.tryParse(match.group(1)!);
    }

    int labelIndex = -1;
    for (int i = 0; i < lines.length; i++) {
      final normalized = normalize(lines[i]);
      if (normalized.contains('卡内余额')) {
        labelIndex = i;
        break;
      }
    }

    if (labelIndex >= 0) {
      for (int i = labelIndex - 1; i >= 0 && i >= labelIndex - 3; i--) {
        final amount = parseAmount(lines[i]);
        if (amount != null) return amount;
      }

      for (
        int i = labelIndex + 1;
        i < lines.length && i <= labelIndex + 3;
        i++
      ) {
        final amount = parseAmount(lines[i]);
        if (amount != null) return amount;
      }
    }

    final compact = normalize(text);
    final inlineMatch = RegExp(
      r'卡内余额([0-9]+(?:\.[0-9]+)?)',
    ).firstMatch(compact);
    if (inlineMatch != null) {
      return double.tryParse(inlineMatch.group(1)!);
    }

    return null;
  }

  Future<double?> fetchBalance() async {
    // The status page is JS-rendered (FineReport), so plain HTTP cannot
    // reliably extract the balance. Return cached value only; the real
    // balance is captured via WebView in CampusCardPage.
    return _cachedBalance;
  }

  String formatBalance(double? balance) {
    if (balance == null) return '--';

    if (balance == balance.truncateToDouble()) {
      return balance.toStringAsFixed(0);
    }

    return balance
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
}
