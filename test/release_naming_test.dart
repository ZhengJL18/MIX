import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 锁住 CI 发版标题。以前 Release 叫 Hermes、附件叫 app-release.apk，
/// 是 workflow 里写死的名字；发布步骤本身已经有 contents: write 并且能成功。
void main() {
  test('build-apk release is titled MIX and uploads a MIX apk', () {
    final yml = File('.github/workflows/build-apk.yml').readAsStringSync();

    expect(yml, contains('contents: write'));
    expect(yml, contains('name: Publish GitHub Release'));
    expect(yml, contains('echo "title=MIX v1.0.0+\${build}"'));
    expect(yml, contains('name: \${{ steps.apk.outputs.title }}'));
    expect(yml, contains('MIX-\${build}.apk'));
    expect(yml, contains('name: MIX-\${{ github.run_number }}'));
    expect(yml, isNot(contains('name: Hermes')));

    // 只有 push 才发版；附件用改名后的 MIX apk，不再上传 app-release.apk。
    final publish = yml.indexOf('name: Publish GitHub Release');
    expect(publish, greaterThan(0));
    final releaseStep = yml.substring(publish);
    expect(releaseStep, contains("github.event_name == 'push'"));
    expect(releaseStep, contains('steps.apk.outputs.file'));
    expect(releaseStep, isNot(contains('app-release.apk')));
    expect(releaseStep, isNot(contains('Hermes')));
  });
}
