import 'package:flutter/material.dart';

/// Lays out stat cards so they work on phones and tablets alike.
///
/// The screens used `GridView.count` with a fixed `childAspectRatio`, which
/// ties a card's height to its width: a ratio that looks right on a phone
/// makes every card on a tablet several hundred pixels tall, with the value
/// at the top, the label at the bottom and nothing in between. Here the
/// column count follows the available width and each row is exactly as tall
/// as its tallest card's content, so the cards stay compact at any width.
class ResponsiveStatGrid extends StatelessWidget {
  const ResponsiveStatGrid({
    super.key,
    required this.children,
    this.spacing = 12,
    this.minTileWidth = 150,
    this.minColumns = 2,
    this.maxColumns = 4,
  });

  final List<Widget> children;

  /// Gap between cards, both across and down.
  final double spacing;

  /// Narrowest a card may get before a column is dropped.
  final double minTileWidth;
  final int minColumns;
  final int maxColumns;

  /// How many columns fit [width]. Prefers a count that fills every row
  /// (6 cards → 3 + 3 rather than 4 + 2) as long as it gives up no more than
  /// one column to do so.
  static int columnsFor(
    int count,
    double width, {
    double spacing = 12,
    double minTileWidth = 150,
    int minColumns = 2,
    int maxColumns = 4,
  }) {
    if (count <= 1) return 1;
    final lower = minColumns < maxColumns ? minColumns : maxColumns;
    final fit = ((width + spacing) / (minTileWidth + spacing)).floor();
    final cap = fit.clamp(lower, maxColumns).clamp(1, count);
    for (var c = cap; c >= cap - 1 && c >= lower; c--) {
      if (count % c == 0) return c;
    }
    return cap;
  }

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(builder: (context, constraints) {
      final columns = columnsFor(
        children.length,
        constraints.maxWidth,
        spacing: spacing,
        minTileWidth: minTileWidth,
        minColumns: minColumns,
        maxColumns: maxColumns,
      );

      final rows = <Widget>[];
      for (var start = 0; start < children.length; start += columns) {
        final cells = <Widget>[];
        for (var i = 0; i < columns; i++) {
          if (i > 0) cells.add(SizedBox(width: spacing));
          final index = start + i;
          // An empty slot keeps a short last row's cards the same width as
          // the rows above.
          cells.add(Expanded(
            child: index < children.length
                ? children[index]
                : const SizedBox.shrink(),
          ));
        }
        if (rows.isNotEmpty) rows.add(SizedBox(height: spacing));
        rows.add(IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ));
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      );
    });
  }
}
