import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

/// Web: a real browser download into the Downloads folder, via a temporary
/// `<a download>` link. (The Web Share API, which share_plus uses, opens the
/// OS share sheet instead of saving anything.)
Future<String?> saveJpeg(String fileName, Uint8List bytes) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'image/jpeg'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = '$fileName.jpg'
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  // Give the browser a moment to start the download before the URL goes.
  Future.delayed(
      const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
  return null;
}
