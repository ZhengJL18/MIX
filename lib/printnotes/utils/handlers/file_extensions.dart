import 'package:path/path.dart' as path;
import 'package:mix/printnotes/constants/constants.dart';

enum CFileType {
  note,
  image,
  sketch,
  unknown,
}

CFileType fileTypeChecker(String itemPath) {
  String extension = path.extension(itemPath);
  if (allowedNoteExtensions.any((ext) => ext == extension)) {
    return CFileType.note;
  } else if (allowedImageExtensions.any((ext) => ext == extension)) {
    return CFileType.image;
  } else if (allowedSketchExtensions.any((ext) => ext == extension)) {
    return CFileType.sketch;
  } else {
    return CFileType.unknown;
  }
}
