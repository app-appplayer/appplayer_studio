// hello — sample greeting tool; replace it with the package's own verbs.
async function hello(args) {
  const name = (args && args.name) || 'world';
  return { greeting: 'Hello, ' + name };
}
