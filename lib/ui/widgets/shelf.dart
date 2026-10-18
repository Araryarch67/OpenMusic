import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../shell_scope.dart';
import 'page_scaffold.dart';

/// Extra height a [MediaCard] needs below its square artwork (padding + two text lines).
const _cardChrome = 70.0;
const _minCardWidth = 168.0;
const _maxCardWidth = 240.0;

/// A titled row of cards.
///  * Phones: horizontally scrolling strip.
///  * Wider: exactly one row whose cards stretch to fill the width; anything that
///    doesn't fit is reachable through "Show all".
class Shelf extends StatelessWidget {
  const Shelf({super.key, required this.title, required this.cards, this.onShowAll});

  final String title;
  final List<Widget> cards;

  /// Overrides the default "Show all" (a grid of [cards]).
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    if (cards.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const hPad = 14.0;
        final available = constraints.maxWidth - hPad * 2;
        final columns = math.max(2, (available / _minCardWidth).floor());
        final overflow = cards.length > columns;
        void showAll() => onShowAll != null ? onShowAll!() : shell.open(CardGridPage(title: title, cards: cards));

        final header = SectionTitle(title, onShowAll: shell.compact || overflow || onShowAll != null ? showAll : null);
        if (shell.compact) {
          final cardWidth = (available / 2.4).clamp(132.0, 180.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              SizedBox(
                height: cardWidth + _cardChrome,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  itemCount: cards.length,
                  itemBuilder: (_, i) => SizedBox(width: cardWidth, child: cards[i]),
                ),
              ),
            ],
          );
        }
        final cardWidth = available / columns;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: hPad),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final card in cards.take(columns)) SizedBox(width: cardWidth, child: card)],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// "Show all" destination: every card in a grid that reflows with the width.
class CardGridPage extends StatelessWidget {
  const CardGridPage({super.key, required this.title, required this.cards});

  final String title;
  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final text = Theme.of(context).textTheme;
    final pad = shell.compact ? 16.0 : 24.0;
    return PageScaffold(
      title: title,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 12),
            child: Text(title, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
        ),
        SliverLayoutBuilder(
          builder: (context, constraints) {
            final hPad = shell.compact ? 6.0 : 14.0;
            final available = constraints.crossAxisExtent - hPad * 2;
            final minWidth = shell.compact ? 140.0 : _minCardWidth;
            final columns = math.max(2, (available / minWidth).floor());
            final cardWidth = math.min(available / columns, _maxCardWidth * 1.5);
            return SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: hPad),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: cardWidth + _cardChrome,
                ),
                itemCount: cards.length,
                itemBuilder: (_, i) => cards[i],
              ),
            );
          },
        ),
      ],
    );
  }
}
