import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Map widgets (Advanced conformance level)
/// Implements a schematic map view with CustomPainter
/// Supports pan/zoom and marker display
class MapWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract map properties - support design doc 'center' object or flat latitude/longitude.
    // Numeric props are read via `num?` to accept either int or double (JSON
    // literals deserialize to whichever is narrower), then converted.
    final center = properties['center'] as Map<String, dynamic>?;
    double? _asDouble(dynamic raw) =>
        (context.resolve<num?>(raw))?.toDouble();
    final latitude = _asDouble(
            center?['latitude'] ?? center?['lat'] ?? properties['latitude']) ??
        0.0;
    final longitude = _asDouble(
            center?['longitude'] ?? center?['lng'] ?? properties['longitude']) ??
        0.0;
    final zoom = _asDouble(properties['zoom']) ?? 10.0;
    // Spec §10.5: `mapType`. Accepted by schema; the built-in stub renders a
    // schematic grid regardless of type.
    // ignore: unused_local_variable
    final mapType = properties['mapType'] as String? ?? 'standard';
    final markers = context.resolve<List<dynamic>>(properties['markers'] ?? [])
            as List<dynamic>? ??
        [];
    final interactive =
        context.resolve<bool>(properties['interactive'] ?? true);
    final showGrid = context.resolve<bool>(properties['showGrid'] ?? true);
    final showCoordinates =
        context.resolve<bool>(properties['showCoordinates'] ?? true);
    final width = _asDouble(properties['width']);
    final height = _asDouble(properties['height']) ?? 400.0;

    // Extract colors — map tile placeholder remains the pale-green
    // cartography default, but authors can override via
    // `backgroundColor` and the grid line falls back to the active
    // theme divider so it remains subtle in dark mode.
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context) ??
            const Color(0xFFE8F4EA);
    final gridColor =
        parseColor(context.resolve(properties['gridColor']), context) ??
            context.themeManager.getColorValue('outlineVariant') ??
            Colors.grey.shade300;
    final markerColor =
        parseColor(context.resolve(properties['markerColor']), context) ?? Colors.red;

    // Extract action handlers
    final onMarkerTap = properties['onMarkerTap'] as Map<String, dynamic>?;
    final onMapTap = properties['onMapTap'] as Map<String, dynamic>?;

    // Parse markers
    final parsedMarkers = _parseMarkers(markers);

    // Build map widget
    Widget map = _MapWidget(
      centerLatitude: latitude,
      centerLongitude: longitude,
      zoom: zoom,
      markers: parsedMarkers,
      interactive: interactive,
      showGrid: showGrid,
      showCoordinates: showCoordinates,
      backgroundColor: backgroundColor,
      gridColor: gridColor,
      markerColor: markerColor,
      onMarkerTap: onMarkerTap,
      onMapTap: onMapTap,
      context: context,
    );

    map = SizedBox(
      width: width,
      height: height,
      child: map,
    );

    return applyCommonWrappers(map, properties, context);
  }

  List<MapMarker> _parseMarkers(List<dynamic> markers) {
    final List<MapMarker> parsed = [];

    for (var marker in markers) {
      if (marker is Map) {
        final lat = (marker['latitude'] as num?)?.toDouble();
        final lng = (marker['longitude'] as num?)?.toDouble();
        if (lat != null && lng != null) {
          parsed.add(MapMarker(
            latitude: lat,
            longitude: lng,
            title: marker['title']?.toString() ?? '',
            icon: marker['icon']?.toString(),
            color: marker['color']?.toString(),
          ));
        }
      }
    }

    return parsed;
  }
}

/// Map marker data
class MapMarker {
  final double latitude;
  final double longitude;
  final String title;
  final String? icon;
  final String? color;

  MapMarker({
    required this.latitude,
    required this.longitude,
    required this.title,
    this.icon,
    this.color,
  });
}

/// Stateful map widget with pan/zoom support
class _MapWidget extends StatefulWidget {
  final double centerLatitude;
  final double centerLongitude;
  final double zoom;
  final List<MapMarker> markers;
  final bool interactive;
  final bool showGrid;
  final bool showCoordinates;
  final Color backgroundColor;
  final Color gridColor;
  final Color markerColor;
  final Map<String, dynamic>? onMarkerTap;
  final Map<String, dynamic>? onMapTap;
  final RenderContext context;

  const _MapWidget({
    required this.centerLatitude,
    required this.centerLongitude,
    required this.zoom,
    required this.markers,
    required this.interactive,
    required this.showGrid,
    required this.showCoordinates,
    required this.backgroundColor,
    required this.gridColor,
    required this.markerColor,
    this.onMarkerTap,
    this.onMapTap,
    required this.context,
  });

  @override
  State<_MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<_MapWidget> {
  late double _centerLat;
  late double _centerLng;
  late double _zoom;
  Offset _panOffset = Offset.zero;
  double _scale = 1.0;
  Offset? _lastFocalPoint;

  @override
  void initState() {
    super.initState();
    _centerLat = widget.centerLatitude;
    _centerLng = widget.centerLongitude;
    _zoom = widget.zoom.clamp(1.0, 20.0);
  }

  @override
  Widget build(BuildContext context) {
    // Theme slots for overlay chrome (zoom buttons, coordinate box,
    // marker labels, container border). The map tile surface itself
    // stays on `widget.backgroundColor` — author-overridable cartography
    // default, not theme-derived.
    final scheme = Theme.of(context).colorScheme;
    final overlaySurface = scheme.surface;
    final overlayOnSurface = scheme.onSurface;
    final overlayOutline = scheme.outlineVariant;

    Widget mapContent = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CustomPaint(
        painter: _MapPainter(
          centerLatitude: _centerLat,
          centerLongitude: _centerLng,
          zoom: _zoom,
          scale: _scale,
          offset: _panOffset,
          markers: widget.markers,
          showGrid: widget.showGrid,
          showCoordinates: widget.showCoordinates,
          backgroundColor: widget.backgroundColor,
          gridColor: widget.gridColor,
          markerColor: widget.markerColor,
          labelBackground: overlaySurface.withValues(alpha: 0.9),
          labelBorder: overlayOutline,
          labelText: overlayOnSurface,
        ),
        child: Container(),
      ),
    );

    if (widget.interactive) {
      mapContent = GestureDetector(
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        onTapUp: _onTapUp,
        child: mapContent,
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: overlayOutline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          mapContent,
          // Zoom controls
          if (widget.interactive)
            Positioned(
              right: 8,
              bottom: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildZoomButton(
                    Icons.add,
                    _zoomIn,
                    overlaySurface,
                    overlayOnSurface,
                  ),
                  const SizedBox(height: 4),
                  _buildZoomButton(
                    Icons.remove,
                    _zoomOut,
                    overlaySurface,
                    overlayOnSurface,
                  ),
                ],
              ),
            ),
          // Non-interactive indicator
          if (!widget.interactive)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'View only',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.orange.shade800,
                  ),
                ),
              ),
            ),
          // Current coordinates
          if (widget.showCoordinates)
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: overlaySurface.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: Text(
                  '${_centerLat.toStringAsFixed(4)}, ${_centerLng.toStringAsFixed(4)} (z${_zoom.toStringAsFixed(1)})',
                  style: TextStyle(
                    fontSize: 11,
                    color: overlayOnSurface.withValues(alpha: 0.8),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildZoomButton(
    IconData icon,
    VoidCallback onPressed,
    Color background,
    Color foreground,
  ) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
          ),
        ],
      ),
      child: IconButton(
        icon: Icon(icon, size: 16, color: foreground),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      ),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _lastFocalPoint = details.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      // Handle pan
      if (_lastFocalPoint != null) {
        final delta = details.focalPoint - _lastFocalPoint!;
        _panOffset += delta;
        _lastFocalPoint = details.focalPoint;

        // Update center coordinates based on pan
        final pixelsPerDegree = _zoom * 10;
        _centerLat -= delta.dy / pixelsPerDegree;
        _centerLng += delta.dx / pixelsPerDegree;

        // Clamp coordinates
        _centerLat = _centerLat.clamp(-90.0, 90.0);
        _centerLng = _centerLng.clamp(-180.0, 180.0);
      }

      // Handle zoom
      if (details.scale != 1.0) {
        _scale = details.scale.clamp(0.5, 3.0);
        _zoom = (widget.zoom * _scale).clamp(1.0, 20.0);
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    setState(() {
      _panOffset = Offset.zero;
      _lastFocalPoint = null;
    });
  }

  void _onTapUp(TapUpDetails details) {
    // Check if tap is on a marker
    final tappedMarker = _findMarkerAtPosition(details.localPosition);

    if (tappedMarker != null && widget.onMarkerTap != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'latitude': tappedMarker.latitude,
            'longitude': tappedMarker.longitude,
            'title': tappedMarker.title,
          },
        },
      );
      widget.context.actionHandler.execute(widget.onMarkerTap!, eventContext);
    } else if (widget.onMapTap != null) {
      // Calculate tap coordinates
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox != null) {
        final size = renderBox.size;
        final tapLat = _centerLat -
            (details.localPosition.dy - size.height / 2) / (_zoom * 10);
        final tapLng = _centerLng +
            (details.localPosition.dx - size.width / 2) / (_zoom * 10);

        final eventContext = widget.context.createChildContext(
          variables: {
            'event': {
              'latitude': tapLat,
              'longitude': tapLng,
            },
          },
        );
        widget.context.actionHandler.execute(widget.onMapTap!, eventContext);
      }
    }
  }

  MapMarker? _findMarkerAtPosition(Offset position) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;

    final size = renderBox.size;
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final pixelsPerDegree = _zoom * 10;

    for (final marker in widget.markers) {
      final markerX =
          centerX + (marker.longitude - _centerLng) * pixelsPerDegree;
      final markerY =
          centerY - (marker.latitude - _centerLat) * pixelsPerDegree;

      final distance = (Offset(markerX, markerY) - position).distance;
      if (distance < 20) {
        return marker;
      }
    }

    return null;
  }

  void _zoomIn() {
    setState(() {
      _zoom = (_zoom + 1).clamp(1.0, 20.0);
    });
  }

  void _zoomOut() {
    setState(() {
      _zoom = (_zoom - 1).clamp(1.0, 20.0);
    });
  }
}

/// Custom painter for rendering the map
class _MapPainter extends CustomPainter {
  final double centerLatitude;
  final double centerLongitude;
  final double zoom;
  final double scale;
  final Offset offset;
  final List<MapMarker> markers;
  final bool showGrid;
  final bool showCoordinates;
  final Color backgroundColor;
  final Color gridColor;
  final Color markerColor;

  /// Theme-derived chrome for marker labels. Injected from the widget
  /// tree because `CustomPainter` has no BuildContext — a change of
  /// light/dark scheme must propagate via `shouldRepaint`.
  final Color labelBackground;
  final Color labelBorder;
  final Color labelText;

  _MapPainter({
    required this.centerLatitude,
    required this.centerLongitude,
    required this.zoom,
    required this.scale,
    required this.offset,
    required this.markers,
    required this.showGrid,
    required this.showCoordinates,
    required this.backgroundColor,
    required this.gridColor,
    required this.markerColor,
    required this.labelBackground,
    required this.labelBorder,
    required this.labelText,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw background
    final bgPaint = Paint()..color = backgroundColor;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final pixelsPerDegree = zoom * 10;

    // Draw grid
    if (showGrid) {
      _drawGrid(canvas, size, centerX, centerY, pixelsPerDegree);
    }

    // Draw center crosshair
    _drawCrosshair(canvas, size, centerX, centerY);

    // Draw markers
    for (final marker in markers) {
      _drawMarker(canvas, marker, centerX, centerY, pixelsPerDegree);
    }
  }

  void _drawGrid(Canvas canvas, Size size, double centerX, double centerY,
      double pixelsPerDegree) {
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // Calculate grid spacing based on zoom
    double gridSpacing;
    if (zoom < 3) {
      gridSpacing = 30.0;
    } else if (zoom < 6) {
      gridSpacing = 10.0;
    } else if (zoom < 10) {
      gridSpacing = 5.0;
    } else {
      gridSpacing = 1.0;
    }

    // Draw latitude lines
    final minLat =
        centerLatitude - size.height / 2 / pixelsPerDegree - gridSpacing;
    final maxLat =
        centerLatitude + size.height / 2 / pixelsPerDegree + gridSpacing;

    for (double lat = (minLat / gridSpacing).floor() * gridSpacing;
        lat <= maxLat;
        lat += gridSpacing) {
      final y = centerY - (lat - centerLatitude) * pixelsPerDegree;
      if (y >= 0 && y <= size.height) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);

        // Draw label
        if (showCoordinates) {
          textPainter.text = TextSpan(
            text: '${lat.toStringAsFixed(0)}°',
            style: TextStyle(color: gridColor.withValues(alpha: 0.8), fontSize: 9),
          );
          textPainter.layout();
          textPainter.paint(canvas, Offset(4, y - textPainter.height / 2));
        }
      }
    }

    // Draw longitude lines
    final minLng =
        centerLongitude - size.width / 2 / pixelsPerDegree - gridSpacing;
    final maxLng =
        centerLongitude + size.width / 2 / pixelsPerDegree + gridSpacing;

    for (double lng = (minLng / gridSpacing).floor() * gridSpacing;
        lng <= maxLng;
        lng += gridSpacing) {
      final x = centerX + (lng - centerLongitude) * pixelsPerDegree;
      if (x >= 0 && x <= size.width) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);

        // Draw label
        if (showCoordinates) {
          textPainter.text = TextSpan(
            text: '${lng.toStringAsFixed(0)}°',
            style: TextStyle(color: gridColor.withValues(alpha: 0.8), fontSize: 9),
          );
          textPainter.layout();
          textPainter.paint(canvas, Offset(x - textPainter.width / 2, 4));
        }
      }
    }
  }

  void _drawCrosshair(
      Canvas canvas, Size size, double centerX, double centerY) {
    final crosshairPaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    // Horizontal line
    canvas.drawLine(
      Offset(centerX - 10, centerY),
      Offset(centerX + 10, centerY),
      crosshairPaint,
    );

    // Vertical line
    canvas.drawLine(
      Offset(centerX, centerY - 10),
      Offset(centerX, centerY + 10),
      crosshairPaint,
    );
  }

  void _drawMarker(Canvas canvas, MapMarker marker, double centerX,
      double centerY, double pixelsPerDegree) {
    final x = centerX + (marker.longitude - centerLongitude) * pixelsPerDegree;
    final y = centerY - (marker.latitude - centerLatitude) * pixelsPerDegree;

    // Draw marker pin
    final markerPath = Path();
    markerPath.moveTo(x, y + 24);
    markerPath.quadraticBezierTo(x - 12, y, x, y - 12);
    markerPath.quadraticBezierTo(x + 12, y, x, y + 24);

    final markerPaint = Paint()
      ..color = markerColor
      ..style = PaintingStyle.fill;

    canvas.drawPath(markerPath, markerPaint);

    // Draw marker border
    final borderPaint = Paint()
      ..color = markerColor.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawPath(markerPath, borderPaint);

    // Draw inner circle
    final innerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(x, y), 4, innerPaint);

    // Draw marker shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.2)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

    canvas.drawOval(
      Rect.fromCenter(center: Offset(x, y + 26), width: 10, height: 4),
      shadowPaint,
    );

    // Draw title label
    if (marker.title.isNotEmpty) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: marker.title,
          style: TextStyle(
            color: labelText,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      // Draw label background
      final labelRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, y - 22),
          width: textPainter.width + 8,
          height: textPainter.height + 4,
        ),
        const Radius.circular(4),
      );

      final labelBgPaint = Paint()
        ..color = labelBackground.withValues(alpha: 0.9);
      canvas.drawRRect(labelRect, labelBgPaint);

      final labelBorderPaint = Paint()
        ..color = labelBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawRRect(labelRect, labelBorderPaint);

      textPainter.paint(
        canvas,
        Offset(x - textPainter.width / 2, y - 22 - textPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(_MapPainter oldDelegate) {
    return centerLatitude != oldDelegate.centerLatitude ||
        centerLongitude != oldDelegate.centerLongitude ||
        zoom != oldDelegate.zoom ||
        scale != oldDelegate.scale ||
        offset != oldDelegate.offset ||
        markers.length != oldDelegate.markers.length ||
        labelBackground != oldDelegate.labelBackground ||
        labelBorder != oldDelegate.labelBorder ||
        labelText != oldDelegate.labelText;
  }
}
