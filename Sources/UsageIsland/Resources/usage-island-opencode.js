// Usage Island local activity bridge v1. No prompts, tool arguments, credentials,
// inference, permissions or network calls. Loaded by OpenCode's plugin API.
import { mkdir, writeFile, rename } from "node:fs/promises";
import { homedir } from "node:os";
import { join, basename } from "node:path";

export const UsageIslandActivity = async ({ directory, activityDirectory }) => {
  const root = activityDirectory || join(homedir(), ".cache", "usage-island", "activity");
  const file = join(root, `opencode-${process.pid}.json`);
  const startedAt = Date.now() - process.uptime() * 1000;
  const sessions = new Map();
  let writes = Promise.resolve();
  return {
    event: async ({ event }) => {
      const p = event.properties || {};
      const id = p.sessionID || p.info?.id;
      if (typeof id !== "string" || id.length > 200) return;
      const old = sessions.get(id);
      if (event.type === "session.deleted" || event.type === "session.error") sessions.delete(id);
      else {
        let state;
        if (event.type === "session.status") state = p.status?.type === "busy" || p.status?.type === "retry" ? "busy" : p.status?.type === "idle" ? "idle" : undefined;
        if (event.type === "session.idle") state = "idle";
        if (event.type === "permission.asked" || event.type === "question.asked") state = "waiting";
        if (event.type === "permission.replied" || event.type === "question.replied" || event.type === "question.rejected") state = "busy";
        if (!state && event.type !== "session.updated") return;
        sessions.set(id, { id, state: state || old?.state || "idle", name: String(p.info?.title || old?.name || basename(directory || "OpenCode")).slice(0, 200), since: Date.now() });
      }
      while (sessions.size > 64) sessions.delete(sessions.keys().next().value);
      const body = JSON.stringify({ version: 1, pid: process.pid, startedAt, sessions: [...sessions.values()] });
      writes = writes.catch(() => {}).then(async () => {
        await mkdir(root, { recursive: true, mode: 0o700 });
        await writeFile(file + ".tmp", body, { mode: 0o600 });
        await rename(file + ".tmp", file);
      });
      await writes.catch(() => {}); // Telemetry must never fail an agent turn.
    },
  };
};
