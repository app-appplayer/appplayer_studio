// {{name}} — cloud server app tools.
//
// Each exported function is bound to a `tools/call` by the manifest
// declaration (`kind: "ts"`, `target: {entry, fn}`). Do NOT write any
// server bootstrap (no express, no MCP SDK wiring) — the platform shell
// serves /mcp, /health, auth, and ui/kb resources; it compiles this file
// (npm ci && tsc) and invokes the exported functions directly.
//
// Signature contract: async (args: Record<string, unknown>) => unknown.
// The return value is JSON-serialized into the MCP tools/call result;
// throw an Error to surface a tool-call error to the client.
//
// The container is stateless (scale-to-zero) — keep durable state in your
// own infrastructure with your own credentials.

export async function ping(args: { message?: string }): Promise<unknown> {
  return { ok: true, echo: args.message ?? 'pong' };
}
