import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mix/printnotes/markdown/rendering/latex.dart';

void main() {
  test('inline math stays in text style', () {
    final layout = LatexLayout.of(isInline: true, content: r'x^2');
    expect(layout.block, isFalse);
    expect(layout.mathStyle, MathStyle.text);
    expect(layout.scale, 1.0);
  });

  test('display math and matrices use display style', () {
    final block = LatexLayout.of(isInline: false, content: r'\frac{1}{2}');
    expect(block.block, isTrue);
    expect(block.mathStyle, MathStyle.display);
    expect(block.scale, 1.05);

    final matrix = LatexLayout.of(
      isInline: true,
      content: r'\begin{pmatrix} a & b \\ c & d \end{pmatrix}',
    );
    expect(matrix.block, isTrue);
    expect(matrix.mathStyle, MathStyle.display);

    final multiline = LatexLayout.of(isInline: true, content: 'a \\\\\nb');
    expect(multiline.block, isTrue);
  });
}
