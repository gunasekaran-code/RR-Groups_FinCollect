import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fincollect/models/AppNotification.dart';
import 'package:fincollect/widgets/notifications_dropdown_panel.dart';

AppNotification _n(String title, {bool read = false, int minutesAgo = 0}) {
  return AppNotification(
    id: title,
    userId: 'u1',
    title: title,
    body: 'Body of $title',
    type: NotificationType.info,
    read: read,
    timestamp: DateTime(2026, 9, 19, 12).subtract(Duration(minutes: minutesAgo)),
  );
}

Widget _host(Future<List<AppNotification>> Function() loader) {
  return MaterialApp(
    home: Scaffold(
      // Align, not Center, so the panel is free to size itself — the test
      // would pass trivially if the harness forced its height.
      body: Align(
        alignment: Alignment.topRight,
        child: NotificationsDropdownPanel(
          width: 268,
          maxHeight: 700,
          onViewAll: () {},
          loader: loader,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('keeps the same size while loading as it does once loaded',
      (tester) async {
    final gate = Completer<List<AppNotification>>();
    await tester.pumpWidget(_host(() => gate.future));
    await tester.pump();

    final whileLoading =
        tester.getSize(find.byType(NotificationsDropdownPanel));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete([_n('One'), _n('Two', minutesAgo: 5)]);
    await tester.pumpAndSettle();

    final whenLoaded = tester.getSize(find.byType(NotificationsDropdownPanel));
    expect(whenLoaded, whileLoading,
        reason: 'the panel must not resize when the fetch lands');
  });

  testWidgets('does not stretch to the full height available', (tester) async {
    await tester.pumpWidget(_host(() async => [_n('One')]));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(NotificationsDropdownPanel));
    expect(size.height, lessThan(500),
        reason: 'must not fill the 700 maxHeight it was handed');
    expect(size.width, 268);
  });

  testWidgets('shows unread only, newest first, capped at the preview count',
      (tester) async {
    await tester.pumpWidget(_host(() async => [
          _n('Read one', read: true),
          _n('Oldest unread', minutesAgo: 50),
          _n('Newest unread', minutesAgo: 1),
          _n('Unread B', minutesAgo: 10),
          _n('Unread C', minutesAgo: 20),
          _n('Unread D', minutesAgo: 30),
        ]));
    await tester.pumpAndSettle();

    expect(find.text('Read one'), findsNothing, reason: 'read is filtered out');
    expect(find.text('Newest unread'), findsOneWidget);
    // 5 unread, but only previewCount fit; the oldest is the one dropped.
    expect(find.text('Oldest unread'), findsNothing);

    // Counting rendered rows would undercount — the list builds lazily and
    // the last row starts below the fold — so read the list's own item count.
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.semanticChildCount, NotificationsDropdownPanel.previewCount);

    // The row past the fold is still there to scroll to.
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.text('Unread D'), findsOneWidget);
  });

  testWidgets('says so when there is nothing unread', (tester) async {
    await tester.pumpWidget(_host(() async => [_n('Read one', read: true)]));
    await tester.pumpAndSettle();

    expect(find.text("You're all caught up"), findsOneWidget);
  });

  testWidgets('reports a failed fetch without showing the raw error',
      (tester) async {
    await tester.pumpWidget(_host(() async => throw Exception('boom')));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load notifications"), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
  });
}
