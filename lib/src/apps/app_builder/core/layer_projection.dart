/// App Builder uses the platform's layer projection — the read-only view
/// that slices the canonical bundle into per-layer typed projections. The
/// fork is gone; this re-exports the single set.
export 'package:appplayer_studio/base.dart'
    show
        LayerProjection,
        AppStructure,
        RouteDef,
        PermissionDef,
        BackgroundPolicy,
        ThemeView,
        ComponentSet,
        PageSlice,
        DashboardSlice,
        NavigationSlice,
        AssetSlice;
