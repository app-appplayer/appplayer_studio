/// Form-template VOCABULARY validation — the enumerable values a template
/// may use. Derived from the published engine types (mcp_bundle 0.4.5
/// `form_port.dart` enums + mcp_form's style layer); supersede with the
/// published form spec (`specs-pub/form`) once it lands.
///
/// Out-of-vocabulary values are REJECTED with a message that lists the
/// allowed values — the feedback an LLM (or a person) needs to correct
/// itself, instead of a silently-adopted value that crashes viewers later.
library;

const Set<String> kBlockTypes = {
  'text',
  'heading',
  'table',
  'chart',
  'image',
  'formField',
  'repeatable',
  'conditional',
  'canvas',
};

const Set<String> kAlignValues = {'left', 'center', 'right', 'justify'};

const Set<String> kOverflowValues = {
  'grow',
  'shrink',
  'shrinkToFit',
  'shrink-to-fit',
  'clip',
  'summarize',
  'summarise',
  'split',
};

const Set<String> kPlacementAnchors = {
  'top-left',
  'top-center',
  'top-right',
  'bottom-left',
  'bottom-center',
  'bottom-right',
  'center',
};

/// Validate the enumerable vocabulary of a template JSON. Returns human/
/// LLM-readable violations ("blocks[seal].style.placement.anchor ...");
/// empty = clean.
List<String> validateTemplateVocabulary(Map<String, dynamic> template) {
  final violations = <String>[];
  final sections = (template['defaultSections'] as List?) ?? const [];
  for (final rawSection in sections) {
    if (rawSection is! Map) continue;
    for (final rawBlock in (rawSection['blocks'] as List?) ?? const []) {
      if (rawBlock is! Map) continue;
      final block = rawBlock.cast<String, dynamic>();
      final id = '${block['blockId'] ?? '?'}';
      final type = block['type'];
      if (type is String && !kBlockTypes.contains(type)) {
        violations.add(
          "blocks[$id].type '$type' is not in the spec. "
          'Allowed: ${kBlockTypes.join(', ')}.',
        );
      }
      final style = (block['style'] as Map?)?.cast<String, dynamic>();
      if (style == null) continue;
      final align = style['align'];
      if (align is String && !kAlignValues.contains(align)) {
        violations.add(
          "blocks[$id].style.align '$align' is not in the spec. "
          'Allowed: ${kAlignValues.join(', ')}.',
        );
      }
      final overflow = style['overflow'];
      if (overflow is String && !kOverflowValues.contains(overflow)) {
        violations.add(
          "blocks[$id].style.overflow '$overflow' is not in the spec. "
          'Allowed: grow, shrink, clip, summarize, split.',
        );
      }
      final placement = (style['placement'] as Map?)?.cast<String, dynamic>();
      if (placement != null) {
        final anchor = placement['anchor'];
        if (anchor is! String || !kPlacementAnchors.contains(anchor)) {
          violations.add(
            "blocks[$id].style.placement.anchor '$anchor' is not in the "
            'spec. Allowed: ${kPlacementAnchors.join(', ')}. '
            '(Omit placement entirely for in-flow blocks.)',
          );
        }
        for (final key in const ['x', 'y', 'width']) {
          final v = placement[key];
          if (v != null && v is! num) {
            violations.add(
              "blocks[$id].style.placement.$key must be a number (mm), "
              "got '$v'.",
            );
          }
        }
      }
    }
  }
  return violations;
}
