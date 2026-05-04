import 'package:flutter/material.dart';

import 'import_panel.dart';

/// Shows the dedicated import modal (link paste, browse, drag-and-drop,
/// YouTube search).
///
/// BUG 4: we no longer wrap the panel in a `ListView`. Instead the dialog
/// content is a fixed-size `Column` with `ImportPanel(fillHeight: true)`
/// so the panel expands to fill available space and no outer scroll is
/// needed. The size is clamped to the smaller of a comfortable desktop
/// size and the current screen — so the same dialog fits cleanly on
/// phones, tablets, and desktops.
Future<void> showPlamusImportDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final media = MediaQuery.of(ctx).size;
      // Leave room for the dialog's own chrome + Close button.
      final width = media.width < 540 ? media.width - 32 : 500.0;
      final height = media.height < 640 ? media.height - 140 : 560.0;
      return AlertDialog(
        title: const Text('Import music'),
        content: SizedBox(
          width: width,
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(ctx)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Search YouTube, paste a media link, or browse local files',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ImportPanel(
                  fillHeight: true,
                  onDone: () {
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
