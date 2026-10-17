import 'package:flutter_test/flutter_test.dart';
import 'package:geo_attendance/main.dart';

void main() {
  testWidgets('login screen is shown when logged out', (tester) async {
    await tester.pumpWidget(const GeoAttendanceApp(initiallyLoggedIn: false));
    expect(find.text('نظام الحضور الجغرافي'), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsOneWidget);
  });
}
