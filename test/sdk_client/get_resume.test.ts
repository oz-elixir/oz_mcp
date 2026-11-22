import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { LoggingMessageNotificationSchema } from "@modelcontextprotocol/sdk/types.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { connectStdio, newClient, startHttpServer, type HttpServer } from "./harness.js";

function nextLogMessage(client: Client, ms = 15_000): Promise<string> {
  return new Promise((ok, fail) => {
    const timer = setTimeout(() => fail(new Error(`no log message in ${ms} ms`)), ms);
    client.setNotificationHandler(LoggingMessageNotificationSchema, (n) => {
      clearTimeout(timer);
      ok(String(n.params.data));
    });
  });
}

describe("GET stream with a resume", () => {
  let http: HttpServer;
  before(async () => { http = await startHttpServer(); });
  after(async () => { await http.stop(); });

  it("http: gets a message sent while no GET stream is live", async () => {
    const gets: Array<string | null> = [];
    let firstGetClosed!: () => void;
    const firstGetEnd = new Promise<void>((ok) => { firstGetClosed = ok; });

    // Records each GET and its Last-Event-ID and tells when the body of
    // the first GET ends (the server closed the stream).
    const recordingFetch: typeof fetch = async (input, init) => {
      const isGet = (init?.method ?? "GET") === "GET";
      if (isGet) gets.push(new Headers(init?.headers).get("last-event-id"));
      const response = await fetch(input, init);
      if (!isGet || gets.length !== 1 || !response.body) return response;

      const body = response.body.pipeThrough(
        new TransformStream({ flush: () => firstGetClosed() }),
      );
      return new Response(body, { status: response.status, headers: response.headers });
    };

    const client = newClient();
    const transport = new StreamableHTTPClientTransport(http.url, { fetch: recordingFetch });
    const message = nextLogMessage(client);

    await client.connect(transport);
    try {
      await client.setLoggingLevel("info");
      await firstGetEnd;

      // The SDK waits the retry hint (2 s) before it reconnects: the
      // message goes to the ring of the closed stream.
      await client.callTool({ name: "sdk_notify", arguments: {} });

      assert.equal(await message, "from-get-stream");
      assert.ok(gets.length >= 2, `expected a reconnect, got ${gets.length} GET`);
      assert.equal(gets[0], null, "the first GET has no Last-Event-ID");
      assert.ok(gets[1], "no Last-Event-ID on the reconnect");
    } finally {
      await client.close();
    }
  });

  it("stdio: gets a message sent with no request open", async () => {
    const client = newClient();
    const message = nextLogMessage(client);
    await connectStdio(client);
    try {
      await client.setLoggingLevel("info");
      await client.callTool({ name: "sdk_notify", arguments: {} });
      assert.equal(await message, "from-get-stream");
    } finally {
      await client.close();
    }
  });
});
