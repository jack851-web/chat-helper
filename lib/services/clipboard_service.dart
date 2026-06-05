import 'package:flutter/services.dart';

class ClipboardService {
  Future<void> copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<String?> paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }
}
