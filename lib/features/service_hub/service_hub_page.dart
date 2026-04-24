import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../core/config/feature_entry_catalog.dart';
import 'service_hub_layout.dart';
import 'widgets/service_hub_card.dart';
import 'widgets/service_hub_header.dart';

class ServiceHubPage extends StatelessWidget {
  const ServiceHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cards = FeatureEntryCatalog.instance.entriesByPlacement(
      FeatureEntryPlacement.serviceHub,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('功能')),
      body: SafeArea(
        top: false,
        child: cards.isEmpty
            ? Center(
                child: Text(
                  '暂无功能入口',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = serviceHubGridColumnCount(
                    constraints.maxWidth,
                  );
                  final horizontalPadding = constraints.maxWidth >= 900
                      ? 24.0
                      : 16.0;

                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      16,
                      horizontalPadding,
                      28,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const ServiceHubHeader(),
                        const SizedBox(height: 18),
                        StaggeredGrid.count(
                          crossAxisCount: crossAxisCount,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          children: [
                            for (final card in cards)
                              () {
                                final activeSpan = serviceHubActiveSpan(
                                  card,
                                  crossAxisCount,
                                );
                                return StaggeredGridTile.fit(
                                  crossAxisCellCount: activeSpan.columns,
                                  child: ServiceHubCard(
                                    card: card,
                                    activeSpan: activeSpan,
                                    activeCardType: serviceHubActiveCardType(
                                      card,
                                      crossAxisCount,
                                    ),
                                  ),
                                );
                              }(),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
