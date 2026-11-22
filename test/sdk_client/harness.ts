import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { resolve } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

export const ROOT = resolve(import.meta.dirname, "../..");

async function freePort(): Promise<number> {
  return new Promise((ok, fail) => {
    const srv = createServer();
    srv.once("error", fail);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address() as { port: number };
      srv.close(() => ok(port));
    });
  });
}

export interface HttpServer {
  url: URL;
  stop: () => Promise<void>;
}

/** Starts the SDK server over HTTP and waits for its READY line. */
export async function startHttpServer(): Promise<HttpServer> {
  const port = await freePort();
  const child: ChildProcess = spawn(
    "mix",
    ["run", "test/e2e/support/serve_sdk.exs", String(port)],
    { cwd: ROOT, env: { ...process.env, MIX_ENV: "test" }, stdio: ["ignore", "pipe", "inherit"] },
  );

  await new Promise<void>((ok, fail) => {
    let seen = "";
    child.stdout!.on("data", (chunk) => {
      seen += chunk.toString();
      if (seen.includes("READY")) ok();
    });
    child.once("exit", (code) => fail(new Error(`server exited early: ${code}`)));
  });

  return {
    url: new URL(`http://127.0.0.1:${port}/mcp`),
    stop: () =>
      new Promise((ok) => {
        if (child.exitCode !== null || child.signalCode !== null) return ok();
        child.once("exit", () => ok());
        child.kill("SIGTERM");
      }),
  };
}

export const capabilities = { elicitation: { form: {} } };

export function newClient(): Client {
  return new Client({ name: "oz-mcp-sdk-test", version: "0.0.0" }, { capabilities });
}

export async function connectHttp(url: URL, client = newClient()): Promise<Client> {
  await client.connect(new StreamableHTTPClientTransport(url));
  return client;
}

export async function connectStdio(client = newClient()): Promise<Client> {
  await client.connect(
    new StdioClientTransport({
      command: "mix",
      args: ["oz_mcp.stdio", "OzMcp.E2E.SdkServer"],
      cwd: ROOT,
      // The full environment, not the safe subset of the SDK.
      env: { ...(process.env as Record<string, string>), MIX_ENV: "test" },
      stderr: "inherit",
    }),
  );
  return client;
}
