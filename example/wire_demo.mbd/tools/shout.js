// Phase 5.6 testbed tool. Single sync function — no host atom usage,
// no Promise — exercising the simplest dispatch path. The host wraps
// the call in `Promise.resolve(...)` so even sync returns are valid.
function shout(args) {
  var text = (args && args.text) || '';
  return { shouted: text.toUpperCase() };
}
