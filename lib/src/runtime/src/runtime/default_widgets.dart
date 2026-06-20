import 'widget_registry.dart';

// Layout widgets
import '../widgets/layout/linear_factory.dart';
import '../widgets/layout/stack_factory.dart';
import '../widgets/layout/container_factory.dart';
import '../widgets/layout/center_factory.dart';
import '../widgets/layout/align_factory.dart';
import '../widgets/layout/padding_factory.dart';
import '../widgets/layout/sizedbox_factory.dart';
import '../widgets/layout/expanded_factory.dart';
import '../widgets/layout/flexible_factory.dart';
import '../widgets/layout/spacer_factory.dart';
import '../widgets/layout/wrap_factory.dart';
import '../widgets/layout/positioned_factory.dart';
import '../widgets/layout/intrinsicheight_factory.dart';
import '../widgets/layout/intrinsicwidth_factory.dart';
import '../widgets/layout/visibility_factory.dart';
import '../widgets/layout/aspectratio_factory.dart';
import '../widgets/layout/baseline_factory.dart';
import '../widgets/layout/fittedbox_factory.dart';
import '../widgets/layout/limitedbox_factory.dart';
import '../widgets/layout/conditional_factory.dart';
import '../widgets/layout/indexed_stack_factory.dart';
import '../widgets/layout/use_template_factory.dart';
import '../templates/template_registry.dart';

// Display widgets
import '../widgets/display/text_factory.dart';
import '../widgets/display/richtext_factory.dart';
import '../widgets/display/image_factory.dart';
import '../widgets/display/icon_factory.dart';
import '../widgets/display/card_factory.dart';
import '../widgets/display/divider_factory.dart';
import '../widgets/display/badge_factory.dart';
import '../widgets/display/chip_factory.dart';
import '../widgets/display/avatar_factory.dart';
import '../widgets/display/tooltip_factory.dart';
import '../widgets/display/placeholder_factory.dart';
import '../widgets/display/banner_factory.dart';
import '../widgets/display/clipoval_factory.dart';
import '../widgets/display/cliprrect_factory.dart';
import '../widgets/display/progress_factory.dart';
import '../widgets/display/verticaldivider_factory.dart';
import '../widgets/display/decoration_factory.dart';

// Layout widgets (additional)
import '../widgets/layout/flow_factory.dart';
import '../widgets/layout/margin_factory.dart';
import '../widgets/layout/layoutbuilder_factory.dart';

// Input widgets
import '../widgets/input/button_factory.dart';
import '../widgets/input/textfield_factory.dart';
import '../widgets/input/checkbox_factory.dart';
import '../widgets/input/radio_factory.dart';
import '../widgets/input/switch_factory.dart';
import '../widgets/input/slider_factory.dart';
import '../widgets/input/rangeslider_factory.dart';
import '../widgets/input/dropdown_factory.dart';
import '../widgets/input/iconbutton_factory.dart';
import '../widgets/input/form_factory.dart';
import '../widgets/input/number_field_factory.dart';
import '../widgets/input/color_picker_factory.dart';
import '../widgets/input/radio_group_factory.dart';
import '../widgets/input/checkbox_group_factory.dart';
import '../widgets/input/segmented_control_factory.dart';
import '../widgets/input/date_field_factory.dart';
import '../widgets/input/time_field_factory.dart';
import '../widgets/input/date_range_picker_factory.dart';
import '../widgets/input/datepicker_factory.dart';
import '../widgets/input/timepicker_factory.dart';
import '../widgets/input/stepper_factory.dart';

// List widgets
import '../widgets/list/listview_factory.dart';
import '../widgets/list/gridview_factory.dart';
import '../widgets/list/listtile_factory.dart';

// Navigation widgets
import '../widgets/navigation/appbar_factory.dart';
import '../widgets/navigation/tabbar_factory.dart';
import '../widgets/navigation/drawer_factory.dart';
import '../widgets/navigation/bottomnavigationbar_factory.dart';
import '../widgets/navigation/navigationrail_factory.dart';
import '../widgets/navigation/floatingactionbutton_factory.dart';
import '../widgets/navigation/popupmenubutton_factory.dart';
import '../widgets/navigation/tabbarview_factory.dart';

// Scroll widgets
import '../widgets/scroll/singlechildscrollview_factory.dart';
import '../widgets/scroll/scrollbar_factory.dart';
import '../widgets/scroll/scroll_view_factory.dart';
import '../widgets/scroll/pageview_factory.dart';

// Animation widgets
import '../widgets/animation/animatedcontainer_factory.dart';
import '../widgets/animation/opacity_factory.dart';
import '../widgets/animation/animated_simple_factories.dart';
import '../widgets/phase_2_4_factories.dart';
import '../widgets/animation/transform_factory.dart';

// v1.3 Display widgets
import '../widgets/display/canvas_factory.dart';
import '../widgets/display/dashboard_factory.dart';

// Interactive widgets
import '../widgets/interactive/gesturedetector_factory.dart';
import '../widgets/interactive/inkwell_factory.dart';
import '../widgets/interactive/draggable_factory.dart';
import '../widgets/interactive/drag_target_factory.dart';

// Dialog widgets
import '../widgets/dialog/alertdialog_factory.dart';
import '../widgets/dialog/snackbar_factory.dart';
import '../widgets/dialog/bottomsheet_factory.dart';
import '../widgets/dialog/simple_dialog_factory.dart';
import '../widgets/dialog/dialog_factory.dart';

// Advanced widgets
import '../widgets/layout/table_factory.dart';
import '../widgets/advanced/data_table_factory.dart';
import '../widgets/advanced/chart_factory.dart';
import '../widgets/advanced/map_factory.dart';
import '../widgets/advanced/media_player_factory.dart';
import '../widgets/advanced/calendar_factory.dart';
import '../widgets/advanced/tree_factory.dart';
import '../widgets/advanced/timeline_factory.dart';
import '../widgets/advanced/gauge_factory.dart';
import '../widgets/advanced/heatmap_factory.dart';
// v1.1 Advanced widgets
import '../widgets/advanced/code_editor_factory.dart';
import '../widgets/advanced/terminal_factory.dart';
import '../widgets/advanced/file_explorer_factory.dart';
import '../widgets/advanced/markdown_factory.dart';
import '../widgets/advanced/webview_factory.dart';
import '../widgets/advanced/signature_factory.dart';

// Accessibility widgets
import '../widgets/accessibility/accessible_wrapper_factory.dart';

// New v1.1 widget factories
import '../widgets/advanced/graph_factory.dart';
import '../widgets/advanced/network_graph_factory.dart';
import '../widgets/layout/fractionally_sized_factory.dart';
import '../widgets/layout/media_query_factory.dart';
import '../widgets/layout/safe_area_factory.dart';
import '../widgets/performance/lazy_factory.dart';
import '../widgets/security/permission_prompt_factory.dart';
import '../widgets/security/offline_fallback_factory.dart';
import '../widgets/security/error_recovery_factory.dart';
import '../widgets/layout/error_boundary_factory.dart';
import '../widgets/animation/lottie_animation_factory.dart';
import '../widgets/input/number_stepper_factory.dart';
import '../widgets/input/rating_factory.dart';

/// Default widget registration
class DefaultWidgets {
  /// Register all default widgets
  static void registerAll(WidgetRegistry registry) {
    // Layout widgets - Spec v1.0 names
    registry.register('linear', LinearLayoutFactory()); // New spec v1.0
    registry.register(
        'box', ContainerWidgetFactory()); // Spec v1.0: box = container

    // Core spec v1.0 layout widgets

    // Common layout widgets
    registry.register('stack', StackWidgetFactory());
    registry.register('center', CenterWidgetFactory());
    registry.register('align', AlignWidgetFactory());
    registry.register('padding', PaddingWidgetFactory());
    registry.register('sizedBox', SizedBoxWidgetFactory()); // CamelCase
    registry.register('expanded', ExpandedWidgetFactory());
    registry.register('flexible', FlexibleWidgetFactory());
    registry.register('spacer', SpacerWidgetFactory());
    registry.register('wrap', WrapWidgetFactory());
    registry.register('positioned', PositionedWidgetFactory());
    registry.register(
        'intrinsicHeight', IntrinsicHeightWidgetFactory()); // CamelCase
    registry.register(
        'intrinsicWidth', IntrinsicWidthWidgetFactory()); // CamelCase
    registry.register('visibility', VisibilityWidgetFactory());
    registry.register('aspectRatio', AspectRatioWidgetFactory()); // CamelCase
    registry.register('baseline', BaselineWidgetFactory());
    // `constrainedBox` / `constrained` are runtime-only legacy aliases
    // of `box`. Spec § 2.4.1 declares `box` as the canonical surface and
    // every constraint they expressed (min/max width/height) is now a
    // property of `box`; new bundles SHOULD emit `box`. We keep the
    // registration so already-distributed bundles continue rendering.
    registry.register('constrainedBox', ContainerWidgetFactory());
    registry.register('constrained', ContainerWidgetFactory());
    registry.register('fittedBox', FittedBoxWidgetFactory()); // CamelCase
    registry.register('limitedBox', LimitedBoxWidgetFactory()); // CamelCase
    registry.register('conditional', ConditionalFactory()); // MCP UI DSL v1.0
    registry.register('indexedStack', IndexedStackWidgetFactory()); // CamelCase

    // Display widgets
    registry.register('text', TextWidgetFactory());
    registry.register('richText', RichTextWidgetFactory()); // CamelCase
    registry.register('image', ImageWidgetFactory());
    registry.register('icon', IconWidgetFactory());
    registry.register('card', CardWidgetFactory());
    registry.register('divider', DividerWidgetFactory());
    registry.register('badge', BadgeWidgetFactory());
    registry.register('chip', ChipWidgetFactory());
    registry.register('avatar', AvatarWidgetFactory());
    // circleAvatar is an alias for avatar - removed for spec compliance
    registry.register('tooltip', TooltipWidgetFactory());
    registry.register('placeholder', PlaceholderWidgetFactory());
    registry.register('banner', BannerWidgetFactory());
    registry.register('clipOval', ClipOvalWidgetFactory()); // CamelCase
    registry.register('clipRRect', ClipRRectWidgetFactory()); // CamelCase
    // `decoratedBox` is a runtime-only legacy alias of `box`. Canonical
    // form is `{type: box, decoration: ..., child: ...}`; the alias
    // remains so already-distributed bundles continue rendering.
    registry.register('decoratedBox', ContainerWidgetFactory());

    // Progress indicators - MCP UI DSL v1.0 uses CamelCase.
    // Canonical: `progressBar` per §17.3.1. Aliases registered explicitly
    // so factory schema conformance passes.
    registry.register('loadingIndicator', ProgressWidgetFactory());
    registry.register('progressBar', ProgressWidgetFactory());
    registry.register('progress', ProgressWidgetFactory());
    registry.register('linearProgressIndicator', ProgressWidgetFactory());

    // Input widgets - Spec v1.0 names
    registry.register(
        'textInput', TextFieldWidgetFactory()); // CamelCase per spec
    registry.register(
        'toggle', SwitchWidgetFactory()); // Spec v1.0: toggle (ARIA role: switch)
    registry.register('select', DropdownWidgetFactory()); // Spec v1.0

    // Common input widgets
    registry.register('button', ButtonWidgetFactory());
    registry.register('checkbox', CheckboxWidgetFactory());
    registry.register('radio', RadioWidgetFactory());
    registry.register('slider', SliderWidgetFactory());
    registry.register('rangeSlider', RangeSliderWidgetFactory()); // CamelCase

    // Legacy alias for textInput per spec §17.3.1 (§17.5.2: runtimes MUST
    // accept registered aliases). Form-aware behavior (binding, validation)
    // is folded into `textInput` via TextFieldWidgetFactory, which supports
    // both validation shapes per §7.2.1.
    registry.register('textFormField', TextFieldWidgetFactory());

    // Additional input widgets
    registry.register('iconButton', IconButtonWidgetFactory()); // CamelCase
    registry.register('form', FormWidgetFactory());

    // Extended input widgets - CamelCase per spec
    registry.register('numberField', NumberFieldFactory());
    registry.register('colorPicker', ColorPickerFactory());
    registry.register('radioGroup', RadioGroupFactory());
    registry.register('checkboxGroup', CheckboxGroupFactory());
    registry.register('segmentedControl', SegmentedControlFactory());
    registry.register('dateField', DateFieldFactory());
    registry.register('timeField', TimeFieldFactory());
    registry.register('dateRangePicker', DateRangePickerFactory());
    registry.register('datePicker', DatePickerWidgetFactory());
    registry.register('timePicker', TimePickerWidgetFactory());
    registry.register('stepper', StepperWidgetFactory());

    // List widgets - spec v1.0 names
    registry.register('list', ListViewWidgetFactory());
    registry.register('listView',
        ListViewWidgetFactory()); // Also register listView for v1.0 spec
    registry.register('grid', GridViewWidgetFactory());
    registry.register('listItem', ListTileWidgetFactory()); // Canonical per spec §17.2.1
    registry.register('listTile', ListTileWidgetFactory()); // Legacy alias per §17.3.1

    // Navigation widgets - Spec v1.0 names
    registry.register('headerBar', AppBarWidgetFactory()); // CamelCase per spec
    registry.register('bottomNav',
        BottomNavigationBarWidgetFactory()); // Spec v1.0: bottomNav
    registry.register('bottomNavigation',
        BottomNavigationBarWidgetFactory()); // Also register bottomNavigation

    // Common navigation widgets
    registry.register('tabBar', TabBarWidgetFactory()); // CamelCase
    registry.register('drawer', DrawerWidgetFactory());
    registry.register(
        'navigationRail', NavigationRailWidgetFactory()); // CamelCase
    registry.register('floatingActionButton',
        FloatingActionButtonWidgetFactory()); // CamelCase
    registry.register(
        'popupMenuButton', PopupMenuButtonWidgetFactory()); // CamelCase
    registry.register('tabBarView', TabBarViewWidgetFactory()); // CamelCase

    // Scroll widgets
    registry.register('scrollView', ScrollViewFactory()); // CamelCase per spec
    registry.register('singleChildScrollView',
        SingleChildScrollViewWidgetFactory()); // CamelCase
    registry.register('scrollBar', ScrollbarWidgetFactory()); // CamelCase
    registry.register('pageView', PageViewWidgetFactory()); // CamelCase

    // Animation widgets
    registry.register(
        'animatedContainer', AnimatedContainerWidgetFactory()); // CamelCase
    registry.register('opacity', OpacityWidgetFactory()); // v1.3
    registry.register('transform', TransformWidgetFactory()); // v1.3
    // v1.3 Phase 3 motion — implicit-anim wrappers + hero
    registry.register('animatedOpacity', AnimatedOpacityWidgetFactory());
    registry.register('animatedAlign', AnimatedAlignWidgetFactory());
    registry.register('animatedPositioned', AnimatedPositionedWidgetFactory());
    registry.register(
        'animatedDefaultTextStyle', AnimatedDefaultTextStyleWidgetFactory());
    registry.register('hero', HeroWidgetFactory());
    registry.register('scrollAnimated', ScrollAnimatedWidgetFactory());
    registry.register('rive', RiveWidgetFactory());
    // v1.3 Phase 2 gallery layouts
    registry.register('staggeredGrid', StaggeredGridWidgetFactory());
    registry.register('carousel', CarouselWidgetFactory());
    // v1.3 Phase 4 media accents
    registry.register('lightbox', LightboxWidgetFactory());
    registry.register('kenBurnsImage', KenBurnsImageWidgetFactory());
    registry.register('imageFilter', ImageFilterWidgetFactory());

    // v1.3 Display widgets
    registry.register('canvas', CanvasWidgetFactory()); // v1.3
    registry.register('dashboard', DashboardWidgetFactory()); // v1.3

    // Interactive widgets
    registry.register(
        'gestureDetector', GestureDetectorWidgetFactory()); // CamelCase
    registry.register('inkWell', InkWellWidgetFactory()); // CamelCase
    registry.register('draggable', DraggableFactory());
    registry.register('dragTarget', DragTargetFactory()); // CamelCase

    // Dialog widgets
    registry.register('alertDialog', AlertDialogWidgetFactory()); // CamelCase
    registry.register('snackBar', SnackBarWidgetFactory()); // CamelCase
    registry.register('bottomSheet', BottomSheetWidgetFactory()); // CamelCase
    registry.register('simpleDialog', SimpleDialogWidgetFactory()); // CamelCase
    registry.register('customDialog', DialogWidgetFactory()); // CamelCase

    // Additional display widgets
    registry.register(
        'verticalDivider', VerticalDividerWidgetFactory()); // CamelCase
    registry.register('decoration', DecorationWidgetFactory());

    // Additional layout widgets
    registry.register('flow', FlowWidgetFactory());
    registry.register('margin', MarginWidgetFactory());

    // Advanced widgets - Spec v1.0
    registry.register('table', TableWidgetFactory()); // Layout table
    registry.register('dataTable', DataTableWidgetFactory()); // Data-bound table
    registry.register('chart', ChartWidgetFactory());
    registry.register('map', MapWidgetFactory());
    registry.register(
        'mediaPlayer', MediaPlayerWidgetFactory()); // CamelCase per spec
    registry.register('calendar', CalendarWidgetFactory());
    registry.register('tree', TreeWidgetFactory());
    registry.register('timeline', TimelineWidgetFactory());
    registry.register('gauge', GaugeWidgetFactory());
    registry.register('heatmap', HeatmapWidgetFactory());
    registry.register('graph', GraphWidgetFactory()); // Simple line/bar graph

    // v1.1 Advanced widgets
    registry.register('codeEditor', CodeEditorWidgetFactory());
    registry.register('terminal', TerminalWidgetFactory());
    registry.register('fileExplorer', FileExplorerWidgetFactory());
    registry.register('markdown', MarkdownWidgetFactory());
    registry.register('webView', WebViewWidgetFactory());
    registry.register('signature', SignatureWidgetFactory());

    // Accessibility widgets
    registry.register('accessibleWrapper', AccessibleWrapperFactory());

    // v1.1 New widget types
    registry.register('networkGraph', NetworkGraphWidgetFactory()); // Network graph with nodes and edges
    registry.register('fractionallySized', FractionallySizedWidgetFactory());
    registry.register('lazy', LazyWidgetFactory());
    registry.register('permissionPrompt', PermissionPromptWidgetFactory());
    registry.register('offlineFallback', OfflineFallbackWidgetFactory());
    registry.register('errorRecovery', ErrorRecoveryWidgetFactory());
    registry.register('errorBoundary', ErrorBoundaryFactory()); // Utility widget (v1.1)
    registry.register('lottieAnimation', LottieAnimationWidgetFactory());
    registry.register('numberStepper', NumberStepperWidgetFactory());
    registry.register('layoutBuilder', LayoutBuilderFactory());
    registry.register('rating', RatingFactory());

    // Responsive layout widgets (v1.1 Section 18)
    registry.register('mediaQuery', MediaQueryWidgetFactory());
    registry.register('safeArea', SafeAreaWidgetFactory());

    // Legacy aliases for backward compatibility (semantic aliases)
    registry.register('container', ContainerWidgetFactory());
    registry.register(
        'column', LinearLayoutFactory()); // Column = vertical linear
    registry.register('row', LinearLayoutFactory()); // Row = horizontal linear
    registry.register('switch', SwitchWidgetFactory()); // Legacy alias for toggle
    registry.register('textField', TextFieldWidgetFactory()); // Legacy alias for textInput
    registry.register('textfield', TextFieldWidgetFactory());
    registry.register('dropdown', DropdownWidgetFactory());
    registry.register('listview', ListViewWidgetFactory());
    registry.register('gridview', GridViewWidgetFactory());
    registry.register('appbar', AppBarWidgetFactory());
    registry.register(
        'bottomnavigationbar', BottomNavigationBarWidgetFactory());

    // Kebab-case legacy aliases.
    //
    // Per spec §17.1.2 widget type names are canonical as camelCase. Only
    // the three kebab forms explicitly listed in §17.3.1 Widget Type
    // Aliases are accepted. All other previously-registered kebab spellings
    // have been removed as out-of-spec; DSL authors must use the canonical
    // camelCase widget type (or the lowercase/camelCase legacy aliases
    // declared in §17.3.1).
    registry.register('list-tile', ListTileWidgetFactory());
    registry.register('progress-bar', ProgressWidgetFactory());
    registry.register('loading-indicator', ProgressWidgetFactory());
  }

  /// Register template-related widgets (v1.1 TM-01)
  static void registerTemplateWidgets(
    WidgetRegistry registry,
    TemplateRegistry templateRegistry,
  ) {
    registry.register(
      'use',
      UseTemplateFactory(templateRegistry: templateRegistry),
    );
  }
}
