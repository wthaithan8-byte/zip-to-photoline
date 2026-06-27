import 'package:flutter_test/flutter_test.dart';

import 'package:zip_to_line/main.dart';

void main() {
  testWidgets('shows empty state when no zip has been shared yet', (WidgetTester tester) async {
    await tester.pumpWidget(const ZipToLineApp());
    await tester.pump();

    expect(find.text('ZIP TO PHOTOLINE'), findsOneWidget);
    expect(find.textContaining('ยังไม่มีรูปภาพ'), findsOneWidget);
  });
}
