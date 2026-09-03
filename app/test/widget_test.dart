import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:android_app/main.dart';

void main() {
  testWidgets('shows monitoring dashboard', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartIrrigationApp());

    expect(find.text('Monitoring Tanaman'), findsOneWidget);
    expect(find.text('Kelembaban Tanah'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(find.text('Kontrol Pompa'), findsOneWidget);
  });
}
