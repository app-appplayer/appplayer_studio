/// Channel combination operators for MCP UI DSL v1.1
///
/// Provides operators to combine multiple channel streams.
library channel_combinations;

import 'dart:async';

/// Provides stream combination operators for channel data
class ChannelCombinations {
  /// Combine latest values from multiple streams
  ///
  /// Emits a list containing the latest value from each stream whenever
  /// any stream emits a new value. Only starts emitting after all streams
  /// have emitted at least one value.
  static Stream<List<dynamic>> combineLatest(List<Stream<dynamic>> streams) {
    if (streams.isEmpty) {
      return const Stream.empty();
    }

    if (streams.length == 1) {
      return streams.first.map((value) => [value]);
    }

    late StreamController<List<dynamic>> controller;
    final subscriptions = <StreamSubscription<dynamic>>[];
    final latestValues = List<dynamic>.filled(streams.length, null);
    final hasEmitted = List<bool>.filled(streams.length, false);
    int completedCount = 0;

    controller = StreamController<List<dynamic>>.broadcast(
      onListen: () {
        for (int i = 0; i < streams.length; i++) {
          final index = i;
          final subscription = streams[index].listen(
            (data) {
              latestValues[index] = data;
              hasEmitted[index] = true;

              // Only emit when all streams have provided at least one value
              if (hasEmitted.every((e) => e)) {
                controller.add(List<dynamic>.from(latestValues));
              }
            },
            onError: (error, stackTrace) {
              controller.addError(error, stackTrace);
            },
            onDone: () {
              completedCount++;
              if (completedCount >= streams.length) {
                controller.close();
              }
            },
          );
          subscriptions.add(subscription);
        }
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          subscription.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
  }

  /// Merge multiple streams into one
  ///
  /// Emits all events from all streams in the order they arrive.
  /// Completes when all source streams have completed.
  static Stream<dynamic> merge(List<Stream<dynamic>> streams) {
    if (streams.isEmpty) {
      return const Stream.empty();
    }

    if (streams.length == 1) {
      return streams.first;
    }

    late StreamController<dynamic> controller;
    final subscriptions = <StreamSubscription<dynamic>>[];
    int completedCount = 0;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        for (final stream in streams) {
          final subscription = stream.listen(
            (data) {
              controller.add(data);
            },
            onError: (error, stackTrace) {
              controller.addError(error, stackTrace);
            },
            onDone: () {
              completedCount++;
              if (completedCount >= streams.length) {
                controller.close();
              }
            },
          );
          subscriptions.add(subscription);
        }
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          subscription.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
  }

  /// Zip streams together (emit when all have new values)
  ///
  /// Waits until all streams have emitted a new value, then emits a list
  /// containing one value from each stream (in order). Values are consumed
  /// in FIFO order per stream.
  static Stream<List<dynamic>> zip(List<Stream<dynamic>> streams) {
    if (streams.isEmpty) {
      return const Stream.empty();
    }

    if (streams.length == 1) {
      return streams.first.map((value) => [value]);
    }

    late StreamController<List<dynamic>> controller;
    final subscriptions = <StreamSubscription<dynamic>>[];
    final buffers = List<List<dynamic>>.generate(
      streams.length,
      (_) => <dynamic>[],
    );
    final isDone = List<bool>.filled(streams.length, false);

    void tryEmit() {
      // Check if all buffers have at least one value
      if (buffers.every((buffer) => buffer.isNotEmpty)) {
        final values = <dynamic>[];
        for (final buffer in buffers) {
          values.add(buffer.removeAt(0));
        }
        controller.add(values);
      }
    }

    void checkComplete() {
      // Close if any stream is done and its buffer is empty
      for (int i = 0; i < streams.length; i++) {
        if (isDone[i] && buffers[i].isEmpty) {
          controller.close();
          return;
        }
      }
    }

    controller = StreamController<List<dynamic>>.broadcast(
      onListen: () {
        for (int i = 0; i < streams.length; i++) {
          final index = i;
          final subscription = streams[index].listen(
            (data) {
              buffers[index].add(data);
              tryEmit();
            },
            onError: (error, stackTrace) {
              controller.addError(error, stackTrace);
            },
            onDone: () {
              isDone[index] = true;
              checkComplete();
            },
          );
          subscriptions.add(subscription);
        }
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          subscription.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
  }

  /// Race - emit from whichever stream emits first
  ///
  /// Subscribes to all streams and forwards events only from the first
  /// stream that emits a value. All other streams are cancelled.
  static Stream<dynamic> race(List<Stream<dynamic>> streams) {
    if (streams.isEmpty) {
      return const Stream.empty();
    }

    if (streams.length == 1) {
      return streams.first;
    }

    late StreamController<dynamic> controller;
    final subscriptions = <StreamSubscription<dynamic>>[];
    int? winnerIndex;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        for (int i = 0; i < streams.length; i++) {
          final index = i;
          final subscription = streams[index].listen(
            (data) {
              if (winnerIndex == null) {
                // First stream to emit wins
                winnerIndex = index;
                // Cancel all other subscriptions
                for (int j = 0; j < subscriptions.length; j++) {
                  if (j != index) {
                    subscriptions[j].cancel();
                  }
                }
              }
              if (winnerIndex == index) {
                controller.add(data);
              }
            },
            onError: (error, stackTrace) {
              if (winnerIndex == null || winnerIndex == index) {
                controller.addError(error, stackTrace);
              }
            },
            onDone: () {
              if (winnerIndex == null || winnerIndex == index) {
                controller.close();
              }
            },
          );
          subscriptions.add(subscription);
        }
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          subscription.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
  }

  /// Switch to a new inner stream whenever the source emits
  ///
  /// For each event from [source], creates a new inner stream via [mapper],
  /// cancelling any previous inner stream subscription. Only events from the
  /// most recently created inner stream are forwarded.
  static Stream<dynamic> switchMap(
    Stream<dynamic> source,
    Stream<dynamic> Function(dynamic) mapper,
  ) {
    late StreamController<dynamic> controller;
    StreamSubscription<dynamic>? sourceSubscription;
    StreamSubscription<dynamic>? innerSubscription;

    controller = StreamController<dynamic>.broadcast(
      onListen: () {
        sourceSubscription = source.listen(
          (data) {
            // Cancel previous inner subscription
            innerSubscription?.cancel();
            // Subscribe to new inner stream
            innerSubscription = mapper(data).listen(
              (innerData) => controller.add(innerData),
              onError: (error, st) => controller.addError(error, st),
            );
          },
          onError: (error, st) => controller.addError(error, st),
          onDone: () {
            innerSubscription?.cancel();
            controller.close();
          },
        );
      },
      onCancel: () {
        innerSubscription?.cancel();
        sourceSubscription?.cancel();
      },
    );

    return controller.stream;
  }
}
