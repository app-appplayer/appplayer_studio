import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Supported page transition types for MCP UI DSL v1.1
enum PageTransitionType {
  /// Slide transition (left/right/up/down)
  slide,

  /// Fade in/out transition
  fade,

  /// Scale transition (zoom in/out)
  scale,

  /// Shared element transition (hero animation)
  sharedElement,

  /// No transition (instant navigation)
  none,
}

/// Configuration for shared element (Hero) transitions between pages.
///
/// Parsed from widget definitions containing a `sharedElement` JSON block.
/// Widgets with matching [tag] values morph smoothly between pages during
/// navigation using Flutter's Hero widget.
class SharedElementConfig {
  /// Hero tag identifier for matching elements across pages.
  /// Supports binding expressions (e.g., "hero-{{item.id}}").
  final String tag;

  /// Transition duration in milliseconds (default: 400).
  final int transitionDuration;

  /// Animation curve name (default: "easeInOut").
  final String curve;

  const SharedElementConfig({
    required this.tag,
    this.transitionDuration = 400,
    this.curve = 'easeInOut',
  });

  /// Create a SharedElementConfig from a JSON map.
  factory SharedElementConfig.fromJson(Map<String, dynamic> json) {
    return SharedElementConfig(
      tag: json['tag'] as String,
      transitionDuration: json['transitionDuration'] as int? ?? 400,
      curve: json['curve'] as String? ?? 'easeInOut',
    );
  }

  /// Serialize this config to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'tag': tag,
      'transitionDuration': transitionDuration,
      'curve': curve,
    };
  }
}

/// Builds page route transitions for MCP UI DSL v1.1.
///
/// Provides factory methods to create [PageRouteBuilder] instances with
/// various transition animations including slide, fade, scale, shared
/// element, and no-animation transitions.
class PageTransitionBuilder {
  /// Build a page route with the specified transition type.
  ///
  /// [page] - The destination widget to navigate to.
  /// [type] - The transition animation type.
  /// [duration] - Duration of the transition animation.
  /// [curve] - The animation curve to use.
  /// [slideDirection] - Direction for slide transitions (default: 'left').
  static PageRouteBuilder<dynamic> buildTransition({
    required Widget page,
    required PageTransitionType type,
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.easeInOut,
    String slideDirection = 'left',
  }) {
    switch (type) {
      case PageTransitionType.slide:
        return _buildSlideTransition(page, duration, curve, slideDirection);
      case PageTransitionType.fade:
        return _buildFadeTransition(page, duration, curve);
      case PageTransitionType.scale:
        return _buildScaleTransition(page, duration, curve);
      case PageTransitionType.sharedElement:
        return _buildSharedElementTransition(page, duration, curve);
      case PageTransitionType.none:
        return _buildNoTransition(page);
    }
  }

  /// Parse a transition type from a string value
  static PageTransitionType parseType(String? value) {
    switch (value) {
      case 'slide':
        return PageTransitionType.slide;
      case 'fade':
        return PageTransitionType.fade;
      case 'scale':
        return PageTransitionType.scale;
      case 'sharedElement':
        return PageTransitionType.sharedElement;
      case 'none':
        return PageTransitionType.none;
      default:
        return PageTransitionType.fade;
    }
  }

  /// Parse a curve from a string value
  static Curve parseCurve(String? value) {
    switch (value) {
      case 'linear':
        return Curves.linear;
      case 'easeIn':
        return Curves.easeIn;
      case 'easeOut':
        return Curves.easeOut;
      case 'easeInOut':
        return Curves.easeInOut;
      case 'bounceIn':
        return Curves.bounceIn;
      case 'bounceOut':
        return Curves.bounceOut;
      case 'bounceInOut':
        return Curves.bounceInOut;
      case 'elasticIn':
        return Curves.elasticIn;
      case 'elasticOut':
        return Curves.elasticOut;
      case 'elasticInOut':
        return Curves.elasticInOut;
      case 'decelerate':
        return Curves.decelerate;
      case 'fastOutSlowIn':
        return Curves.fastOutSlowIn;
      case 'spring':
        return const _SpringCurve();
      case 'friction':
        return Curves.decelerate; // Friction approximation
      case 'gravity':
        return _GravityCurve();
      default:
        return Curves.easeInOut;
    }
  }

  /// Build a physics-based page transition
  ///
  /// Supports spring, friction, and gravity physics simulations.
  /// Build a physics-based transition widget (per 16-animations.md §8).
  ///
  /// Returns a [Widget] applying spring or gravity physics to [child]
  /// driven by the given [animation].
  static Widget buildPhysicsTransition({
    required Animation<double> animation,
    required Widget child,
    SpringDescription? spring,
    bool useGravity = false,
  }) {
    if (useGravity) {
      final tween = Tween(
        begin: const Offset(0.0, -1.0),
        end: Offset.zero,
      ).chain(CurveTween(curve: _GravityCurve()));
      return SlideTransition(
        position: animation.drive(tween),
        child: child,
      );
    }

    // Spring physics (default)
    final springCurve = _SpringCurve(
      stiffness: spring?.stiffness ?? 100.0,
      damping: spring?.damping ?? 10.0,
    );
    final tween = Tween(begin: const Offset(1.0, 0.0), end: Offset.zero)
        .chain(CurveTween(curve: springCurve));
    return SlideTransition(
      position: animation.drive(tween),
      child: child,
    );
  }

  /// Build a physics-based page route transition.
  ///
  /// Convenience wrapper that creates a full [PageRouteBuilder] with
  /// physics-based animations.
  static PageRouteBuilder<dynamic> buildPhysicsPageRoute({
    required Widget page,
    required String physics,
    Duration duration = const Duration(milliseconds: 500),
    double stiffness = 100.0,
    double damping = 10.0,
    double mass = 1.0,
  }) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        switch (physics) {
          case 'spring':
            // Use CurvedAnimation with a spring curve approximation
            final tween =
                Tween(begin: const Offset(1.0, 0.0), end: Offset.zero);
            return SlideTransition(
              position: animation.drive(tween.chain(CurveTween(
                  curve: _SpringCurve(
                stiffness: stiffness,
                damping: damping,
              )))),
              child: child,
            );

          case 'friction':
            final tween = Tween(begin: 0.0, end: 1.0).chain(
              CurveTween(curve: Curves.decelerate),
            );
            return FadeTransition(
              opacity: animation.drive(tween),
              child: ScaleTransition(
                scale: animation.drive(
                  Tween(begin: 1.2, end: 1.0).chain(
                    CurveTween(curve: Curves.decelerate),
                  ),
                ),
                child: child,
              ),
            );

          case 'gravity':
            final tween = Tween(
              begin: const Offset(0.0, -1.0),
              end: Offset.zero,
            ).chain(CurveTween(curve: _GravityCurve()));
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );

          default:
            return FadeTransition(
              opacity: animation,
              child: child,
            );
        }
      },
    );
  }

  /// Slide transition from the specified direction
  static PageRouteBuilder<dynamic> _buildSlideTransition(
    Widget page,
    Duration duration,
    Curve curve,
    String direction,
  ) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final begin = _getSlideOffset(direction);
        const end = Offset.zero;

        final tween = Tween(begin: begin, end: end).chain(
          CurveTween(curve: curve),
        );

        return SlideTransition(
          position: animation.drive(tween),
          child: child,
        );
      },
    );
  }

  /// Fade transition
  static PageRouteBuilder<dynamic> _buildFadeTransition(
    Widget page,
    Duration duration,
    Curve curve,
  ) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final tween = Tween(begin: 0.0, end: 1.0).chain(
          CurveTween(curve: curve),
        );

        return FadeTransition(
          opacity: animation.drive(tween),
          child: child,
        );
      },
    );
  }

  /// Scale transition (zoom in from center)
  static PageRouteBuilder<dynamic> _buildScaleTransition(
    Widget page,
    Duration duration,
    Curve curve,
  ) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final scaleTween = Tween(begin: 0.0, end: 1.0).chain(
          CurveTween(curve: curve),
        );
        final fadeTween = Tween(begin: 0.0, end: 1.0).chain(
          CurveTween(curve: curve),
        );

        return ScaleTransition(
          scale: animation.drive(scaleTween),
          child: FadeTransition(
            opacity: animation.drive(fadeTween),
            child: child,
          ),
        );
      },
    );
  }

  /// Shared element transition using Hero widget conventions.
  /// The page itself should contain Hero widgets with matching tags.
  static PageRouteBuilder<dynamic> _buildSharedElementTransition(
    Widget page,
    Duration duration,
    Curve curve,
  ) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final tween = Tween(begin: 0.0, end: 1.0).chain(
          CurveTween(curve: curve),
        );

        return FadeTransition(
          opacity: animation.drive(tween),
          child: child,
        );
      },
    );
  }

  /// No transition (instant page change)
  static PageRouteBuilder<dynamic> _buildNoTransition(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return child;
      },
    );
  }

  /// Get the starting offset for a slide transition based on direction
  static Offset _getSlideOffset(String direction) {
    switch (direction) {
      case 'right':
        return const Offset(-1.0, 0.0);
      case 'up':
        return const Offset(0.0, 1.0);
      case 'down':
        return const Offset(0.0, -1.0);
      case 'left':
      default:
        return const Offset(1.0, 0.0);
    }
  }
}

/// Spring physics curve for animations
class _SpringCurve extends Curve {
  final double stiffness;
  final double damping;

  const _SpringCurve({
    this.stiffness = 100.0,
    this.damping = 10.0,
  });

  @override
  double transformInternal(double t) {
    // Damped spring approximation
    final omega = math.sqrt(stiffness);
    final zeta = damping / (2 * omega);

    if (zeta < 1.0) {
      // Under-damped (oscillates)
      final omegaD = omega * math.sqrt(1 - zeta * zeta);
      return 1.0 -
          math.exp(-zeta * omega * t) *
              (math.cos(omegaD * t * math.pi * 2) +
                  (zeta * omega / omegaD) *
                      math.sin(omegaD * t * math.pi * 2));
    } else {
      // Critically or over-damped
      return 1.0 - (1 + omega * t) * math.exp(-omega * t);
    }
  }
}

/// Gravity physics curve for animations
class _GravityCurve extends Curve {
  @override
  double transformInternal(double t) {
    // Quadratic ease simulating gravity with bounce at end
    if (t < 0.7) {
      return (t / 0.7) * (t / 0.7);
    } else {
      // Small bounce
      final bounceT = (t - 0.7) / 0.3;
      return 1.0 - (1.0 - bounceT) * (1.0 - bounceT) * 0.1;
    }
  }
}
