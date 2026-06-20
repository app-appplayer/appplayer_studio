library flutter_mcp_ui_runtime;

// Core exports
export 'src/mcp_ui_runtime.dart' show MCPUIRuntime, MCPUIRuntimeHelper;
export 'src/renderer/render_context.dart';
export 'src/renderer/renderer.dart';
export 'src/runtime/widget_registry.dart';

// Model exports
export 'src/models/ui_definition.dart' hide BackgroundServiceType;
export 'src/models/app_metadata.dart';

// Routing exports
export 'src/routing/route_manager.dart';
export 'src/routing/page_state_scope.dart';

// Runtime exports
export 'src/runtime/runtime_engine.dart';
export 'src/runtime/lifecycle_manager.dart';
export 'src/runtime/service_registry.dart' hide ServiceStatus;
export 'src/runtime/background_service_manager.dart';
export 'src/runtime/conformance_checker.dart';
export 'src/runtime/cache_manager.dart';

// Service exports
export 'src/services/navigation_service.dart';
export 'src/services/dialog_service.dart';
export 'src/services/notification_service.dart';

// Theme exports
export 'src/theme/theme_manager.dart';

// State management exports
export 'src/state/state_manager.dart' show StateManager;
export 'src/state/state_watcher.dart';
export 'src/state/computed_property.dart';

// Binding exports
export 'src/binding/binding_engine.dart';

// Action exports
export 'src/actions/action_handler.dart'
    show ActionHandler, NavigationActionExecutor, ChannelActionExecutor;

// v1.1 exports
export 'src/core/constants/client_action_types.dart';
export 'src/channels/channel_manager.dart';
export 'src/channels/channel_message.dart';
export 'src/channels/rate_limiter.dart';
export 'src/permissions/permission_manager.dart';
export 'src/permissions/trust_level.dart' show TrustLevel, TrustLevelManager;
export 'src/client_actions/client_action_handler.dart';
export 'src/client_resources/client_resource_resolver.dart';
export 'src/client_resources/batch_resource_loader.dart';
export 'src/client_resources/resource_dependency_resolver.dart';

// Notification exports
export 'src/notifications/notification_types.dart';
export 'src/notifications/notification_manager.dart';

// Widget factory exports
export 'src/widgets/widget_factory.dart';

// Utility exports
export 'src/utils/json_path.dart';
export 'src/utils/mcp_logger.dart';

// I18n exports
export 'src/i18n/i18n_manager.dart';
export 'src/i18n/i18n_loader.dart';

// Background service exports (using the runtime version)

// Virtualization exports
export 'src/widgets/virtualized/virtualized_list.dart';

// Debounce/Throttle exports
export 'src/utils/debounce.dart';

// Dependency injection exports
export 'src/core/service_locator.dart';

// Plugin system exports
export 'src/plugins/plugin_system.dart';

// Error boundary exports
export 'src/core/error_boundary.dart';

// Validation exports
export 'src/validation/validation_engine.dart' hide ValidationResult;
export 'src/validation/custom_validator.dart';

// Accessibility exports
export 'src/accessibility/focus_manager.dart';
export 'src/accessibility/live_regions.dart';

// v1.2 Bundle serving exports
export 'src/bundle/bundle_ui_adapter.dart';
export 'src/bundle/bundle_page_adapter.dart';
export 'src/bundle/bundle_asset_provider.dart';

// Responsive form factor + design tokens (spec: responsive rendering plan)
export 'src/form_factor/form_factor.dart';
export 'src/form_factor/view_mode.dart';
export 'src/form_factor/app_tokens.dart';
