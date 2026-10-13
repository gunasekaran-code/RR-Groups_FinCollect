import 'dart:io';
import 'dart:typed_data';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'customer_documents_download.dart' show customerDocumentsAlbum;

/// Android/iOS: into the gallery, in [customerDocumentsAlbum]; returns null.
/// macOS/Windows/Linux: written to the Downloads folder; returns the path.
Future<String?> saveJpeg(String fileName, Uint8List bytes) async {
  if (Platform.isAndroid || Platform.isIOS) {
    if (!await Gal.hasAccess(toAlbum: true) &&
        !await Gal.requestAccess(toAlbum: true)) {
      throw Exception('Permission to save to the gallery was denied.');
    }
    try {
      await Gal.putImageBytes(bytes,
          album: customerDocumentsAlbum, name: fileName);
    } on GalException catch (e) {
      throw Exception(e.type.message);
    }
    return null;
  }

  final dir =
      await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  var file = File('${dir.path}${Platform.pathSeparator}$fileName.jpg');
  // Never overwrite an earlier download: name (1).jpg, name (2).jpg, …
  for (var n = 1; await file.exists(); n++) {
    file = File('${dir.path}${Platform.pathSeparator}$fileName ($n).jpg');
  }
  await file.writeAsBytes(bytes);
  return file.path;
}
