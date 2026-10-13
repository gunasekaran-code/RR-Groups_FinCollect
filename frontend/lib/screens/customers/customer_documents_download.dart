import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'customers_screen.dart' show decodePhotoBytes;
import 'document_saver_io.dart'
    if (dart.library.js_interop) 'document_saver_web.dart' as saver;

/// Gallery album the documents are saved into on Android and iOS.
const String customerDocumentsAlbum = 'RR Groups';

/// Where [downloadDocumentAsJpeg] put the file.
enum DocumentSavedTo {
  /// Android/iOS photo gallery, in [customerDocumentsAlbum].
  gallery,

  /// Web: a browser download, into the browser's download folder.
  browser,

  /// macOS/Windows/Linux: written to the Downloads folder.
  folder,
}

/// Saves one document as a JPEG on this device and reports where it went
/// (with the file path on desktop). Null when the image could not be read.
Future<(DocumentSavedTo, String?)?> downloadDocumentAsJpeg({
  required String customerCode,
  required String label,
  required String? data,
}) async {
  final raw = await loadDocumentBytes(data);
  if (raw == null) return null;
  final jpeg = await compute(_toJpeg, raw);
  if (jpeg == null) return null;

  final prefix = _slug(customerCode.isEmpty ? 'customer' : customerCode);
  final path = await saver.saveJpeg('${prefix}_${_slug(label)}', jpeg);

  if (kIsWeb) return (DocumentSavedTo.browser, null);
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return (DocumentSavedTo.gallery, null);
  }
  return (DocumentSavedTo.folder, path);
}

/// A stored document's bytes: decoded from its base64 data URI, or fetched
/// when the backend returned a plain URL.
Future<Uint8List?> loadDocumentBytes(String? data) async {
  if (data == null || data.isEmpty) return null;
  if (data.startsWith('http://') || data.startsWith('https://')) {
    try {
      final res = await http.get(Uri.parse(data));
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }
  return decodePhotoBytes(data);
}

/// A picked photo as the base64 JPEG data URI the `customers` document
/// columns store. Camera photos are several MB, so the longest side is
/// capped at [maxSide] — still sharp enough to read an Aadhaar or PAN card.
Future<String> encodeDocumentForUpload(Uint8List bytes,
    {int maxSide = 1600}) async {
  final jpeg = await compute(_shrinkToJpeg, (bytes, maxSide));
  return 'data:image/jpeg;base64,${base64Encode(jpeg ?? bytes)}';
}

Uint8List? _shrinkToJpeg((Uint8List, int) args) {
  final (bytes, maxSide) = args;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  var image = decoded;
  if (image.width > maxSide || image.height > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide)
        : img.copyResize(image, height: maxSide);
  }
  return _encodeJpeg(image, quality: 85);
}

/// Re-encodes any image as JPEG; one that already is passes through
/// untouched. Runs off the UI thread via [compute].
Uint8List? _toJpeg(Uint8List bytes) {
  if (bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) return bytes;
  final decoded = img.decodeImage(bytes);
  return decoded == null ? null : _encodeJpeg(decoded, quality: 92);
}

/// JPEG has no transparency, so a transparent PNG (a signature, usually) is
/// laid on white first instead of coming out black.
Uint8List _encodeJpeg(img.Image image, {required int quality}) {
  var flat = image;
  if (image.hasAlpha) {
    flat = img.Image(width: image.width, height: image.height)
      ..clear(img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, image);
  }
  return img.encodeJpg(flat, quality: quality);
}

String _slug(String s) => s
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');
