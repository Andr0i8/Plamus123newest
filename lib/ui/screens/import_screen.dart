import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/library_service.dart';
import '../widgets/import_panel.dart';

/// Full-page import experience (same controls as the modal).
class ImportScreen extends StatelessWidget {
  /// Creates the import screen.
  const ImportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = context.read<LibraryService>();
    // BUG 4: no outer `SingleChildScrollView` — the `ImportPanel` expands to
    // fill the Scaffold body so link-mode (URL field + buttons + drag-drop)
    // and search-mode (query + results) each fit without scrolling. The
    // `fillHeight: true` flag tells the panel to use `Expanded` for its
    // variable-height sections.
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Search / import',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ImportPanel(
                fillHeight: true,
                onDone: () => lib.refreshAll(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
