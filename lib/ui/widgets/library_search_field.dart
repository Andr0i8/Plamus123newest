import 'package:flutter/material.dart';

/// Pill-shaped search field used inside the library and playlist
/// screens to filter the visible track list by title / artist.
///
/// Visually consistent with the segmented control above it in the
/// library (same `surfaceContainerHighest` fill, no border) and with
/// the rounded `FilledButton` "Play all" action (radius matches). A
/// trailing clear button appears as soon as the user types, driven by
/// a [ValueListenableBuilder] so toggling its visibility doesn't force
/// the host widget to rebuild on every keystroke.
class LibrarySearchField extends StatelessWidget {
  /// Creates a search field.
  ///
  /// [controller] owns the input text and survives Provider rebuilds
  /// of the host screen. [onChanged] receives the raw text on every
  /// keystroke — callers are expected to normalize (lowercase, trim)
  /// it themselves and cache the result for filtering.
  const LibrarySearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hintText = 'Search',
  });

  /// Backing controller. The widget never disposes it — the host owns
  /// the controller's lifecycle.
  final TextEditingController controller;

  /// Called on every keystroke with the raw text.
  final ValueChanged<String> onChanged;

  /// Placeholder shown when the field is empty.
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              icon: const Icon(Icons.clear, size: 18),
              tooltip: 'Clear search',
              splashRadius: 18,
              onPressed: () {
                controller.clear();
                onChanged('');
              },
            );
          },
        ),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}
