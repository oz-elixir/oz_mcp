import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { connectHttp, connectStdio, startHttpServer, type HttpServer } from "./harness.js";

describe("initialize and tools", () => {
  let http: HttpServer;
  before(async () => { http = await startHttpServer(); });
  after(async () => { await http.stop(); });

  for (const [label, connect] of [
    ["http", () => connectHttp(http.url)],
    ["stdio", () => connectStdio()],
  ] as const) {
    it(`${label}: initialize, tools/list and tools/call`, async () => {
      const client = await connect();
      try {
        assert.equal(client.getServerVersion()?.name, "sdk-server");
        const caps = client.getServerCapabilities();
        assert.ok(caps?.tools && caps.logging && caps.tasks);

        if (client.transport instanceof StreamableHTTPClientTransport) {
          assert.equal(client.transport.protocolVersion, "2025-11-25");
        }

        const { tools } = await client.listTools();
        assert.deepEqual(
          tools.map((t) => t.name).sort(),
          ["sdk_echo", "sdk_elicit", "sdk_notify", "sdk_task"],
        );

        const result = await client.callTool({ name: "sdk_echo", arguments: { text: "hi" } });
        assert.deepEqual(result.content, [{ type: "text", text: "hi" }]);
      } finally {
        await client.close();
      }
    });
  }
});
