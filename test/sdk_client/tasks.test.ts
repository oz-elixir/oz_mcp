import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import type { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";
import { connectHttp, connectStdio, startHttpServer, type HttpServer } from "./harness.js";

const RELATED_TASK = "io.modelcontextprotocol/related-task";

// The `task` creation params go in the options, the third argument.
function startTask(client: Client, args: Record<string, unknown>) {
  return client.experimental.tasks.callToolStream(
    { name: "sdk_task", arguments: args },
    undefined,
    { task: { ttl: 60_000 } },
  );
}

describe("tasks/result", () => {
  let http: HttpServer;
  before(async () => { http = await startHttpServer(); });
  after(async () => { await http.stop(); });

  for (const [label, connect] of [
    ["http", () => connectHttp(http.url)],
    ["stdio", () => connectStdio()],
  ] as const) {
    it(`${label}: a task runs and tasks/result gives the answer`, async () => {
      const client = await connect();
      try {
        let taskId: string | undefined;
        let last: { type: string } | undefined;

        for await (const message of startTask(client, {})) {
          if (message.type === "taskCreated") taskId = message.task.taskId;
          last = message;
        }
        assert.ok(taskId, "no taskCreated message");
        assert.equal(last?.type, "result");

        const task = await client.experimental.tasks.getTask(taskId);
        assert.equal(task.status, "completed");

        const payload = (await client.experimental.tasks.getTaskResult(
          taskId,
          CallToolResultSchema,
        )) as {
          content: unknown;
          _meta?: Record<string, { taskId?: string }>;
        };
        assert.deepEqual(payload.content, [{ type: "text", text: "task done" }]);
        assert.equal(payload._meta?.[RELATED_TASK]?.taskId, taskId);

        const { tasks } = await client.experimental.tasks.listTasks();
        assert.ok(tasks.some((t) => t.taskId === taskId));
      } finally {
        await client.close();
      }
    });

    it(`${label}: a cancel ends a working task`, async () => {
      const client = await connect();
      try {
        let taskId: string | undefined;
        for await (const message of startTask(client, { hold: true })) {
          if (message.type === "taskCreated") {
            taskId = message.task.taskId;
            break;
          }
        }
        assert.ok(taskId, "no taskCreated message");

        await client.experimental.tasks.cancelTask(taskId);
        const task = await client.experimental.tasks.getTask(taskId);
        assert.equal(task.status, "cancelled");
      } finally {
        await client.close();
      }
    });
  }
});
