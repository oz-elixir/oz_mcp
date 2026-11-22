import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { ElicitRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { connectHttp, connectStdio, newClient, startHttpServer, type HttpServer } from "./harness.js";

type Action = "accept" | "decline" | "cancel";

function clientAnswering(action: Action) {
  const client = newClient();
  const seen: unknown[] = [];
  client.setRequestHandler(ElicitRequestSchema, async (request) => {
    seen.push(request.params);
    return action === "accept"
      ? { action, content: { name: "Ada" } }
      : { action };
  });
  return { client, seen };
}

describe("tools/call with an elicitation", () => {
  let http: HttpServer;
  before(async () => { http = await startHttpServer(); });
  after(async () => { await http.stop(); });

  for (const [label, connect] of [
    ["http", (c: ReturnType<typeof newClient>) => connectHttp(http.url, c)],
    ["stdio", (c: ReturnType<typeof newClient>) => connectStdio(c)],
  ] as const) {
    it(`${label}: accept`, async () => {
      const { client, seen } = clientAnswering("accept");
      await connect(client);
      try {
        const result = await client.callTool({ name: "sdk_elicit", arguments: {} });
        assert.deepEqual(result.content, [{ type: "text", text: "hello Ada" }]);
        assert.equal(seen.length, 1);
      } finally {
        await client.close();
      }
    });

    for (const action of ["decline", "cancel"] as const) {
      it(`${label}: ${action}`, async () => {
        const { client } = clientAnswering(action);
        await connect(client);
        try {
          const result = await client.callTool({ name: "sdk_elicit", arguments: {} });
          assert.deepEqual(result.content, [{ type: "text", text: `action: ${action}` }]);
        } finally {
          await client.close();
        }
      });
    }
  }
});
