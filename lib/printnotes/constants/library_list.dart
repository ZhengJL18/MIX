import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class Library {
  final String name;
  final String publisher;
  final String url;
  final String license;

  Library(
      {required this.name,
      required this.publisher,
      required this.url,
      required this.license});
}

/// 从 assets/oss_licenses.json 加载第三方库列表（运行时加载，避免把
/// oss_licenses.dart 的约 1.9MB 许可证字符串编译进 App）。
Future<List<Library>> loadLibraries() async {
  final String raw = await rootBundle.loadString('assets/oss_licenses.json');
  final List<dynamic> data = jsonDecode(raw) as List<dynamic>;
  return data.map((e) {
    final Map<String, dynamic> lib =
        (e as Map<dynamic, dynamic>).cast<String, dynamic>();
    return Library(
        name: lib['name'] as String? ?? '',
        publisher: getPublisher(lib),
        url: (lib['repository'] as String?) ??
            (lib['homepage'] as String?) ??
            '',
        license: getLicense(lib));
  }).toList();
}

String getPublisher(Map<String, dynamic> lib) {
  String publisher = '...';
  final List<dynamic> authors = lib['authors'] as List<dynamic>? ?? const [];
  final String? homepage = lib['homepage'] as String?;
  final String? repository = lib['repository'] as String?;
  if (authors.isNotEmpty) {
    publisher = authors.join(', ');
  } else if (homepage != null) {
    if (homepage.contains('flutter.dev')) publisher = 'flutter';

    if (homepage.contains('github.com')) {
      Uri? uri = Uri.tryParse(homepage);
      if (uri != null && uri.pathSegments.isNotEmpty) {
        publisher = uri.pathSegments.first;
      }
    }
  } else if (repository != null) {
    Uri? uri = Uri.tryParse(repository);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      publisher = uri.pathSegments.first;
    }
  }
  return publisher;
}

String getLicense(Map<String, dynamic> lib) {
  final List<dynamic> spdx =
      lib['spdxIdentifiers'] as List<dynamic>? ?? const [];
  if (spdx.isNotEmpty) {
    return spdx.join(', ');
  } else {
    return 'Check library for license';
  }
}
