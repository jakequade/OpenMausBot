import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import { resolveAgentBrowserBinary } from "../../server/browser-engine.ts";
import { removeTempDir, waitForExit } from "../../server/testing/cleanup.ts";
import { runControlOmb } from "../control-omb.ts";
import { UI_TOOLS_DIR } from "./control-omb-ui.ts";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const enabled = process.env.OMB_UI_E2E === "1" || Boolean(resolveAgentBrowserBinary({ dataDir: UI_TOOLS_DIR, env: process.env }));

(enabled ? it : it.skip)("coordinates from the real composer and opens the exact child task from its existing inline receipt", async () => {
  const temporary = mkdtempSync(join(tmpdir(), "omb-direct-ui-plan-"));
  const planPath = join(temporary, "plan.json");
  writeFileSync(planPath, "{}");
  const child = spawn(process.execPath, ["--experimental-strip-types", "scripts/control-omb.ts", "ui", "launch"], {
    cwd: ROOT, env: { ...process.env, FAKE_CLAUDE_ROOM_PLAN: planPath }, stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  let error = "";
  child.stdout.on("data", chunk => { output += String(chunk); });
  child.stderr.on("data", chunk => { error += String(chunk); });
  child.on("error", caught => { error += caught.message; });
  let info: { ui: string; url: string; botId: string; logPath: string };
  try {
    await expect.poll(() => {
      if (child.exitCode !== null || child.signalCode !== null) throw new Error(error);
      try { info = JSON.parse(output); return Boolean(info.ui); } catch { return false; }
    }, { timeout: 180_000, interval: 250 }).toBe(true);
    const api = async (path: string, body?: unknown, method = "POST") => {
      const response = await fetch(info.url + path, body === undefined ? {} : {
        method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(JSON.stringify(result));
      return result;
    };
    const ui = (verb: string, ...args: string[]) => runControlOmb(["ui", verb, "--ui", info.ui, ...args]) as Promise<any>;
    const snapshot = async () => (await ui("snapshot")).snapshot as string;
    const click = async (name: string, role = "button") => {
      const refs = (await ui("snapshot")).refs as Record<string, { role: string; name: string }>;
      const match = Object.entries(refs).find(([, entry]) => entry.role === role && entry.name.endsWith(name));
      expect(match).toBeDefined();
      return ui("click", "--ref", "@" + match![0]);
    };
    const lead = (await api("/api/bots", { name: "Engineer", title: "Implementation", section: "" })).bot;
    const gateFile = join(temporary, "finish-teammate");
    writeFileSync(planPath, JSON.stringify({
      [info.botId]: { steps: [{ arguments: { bot_ids: [lead.id], request_key: "review", message: "Check the fixture CSV export" } }], reply: "Assigned", resumeReply: "Engineer checked the fixture CSV export" },
      [lead.id]: { gateFile, reply: "CSV export checked in my separate task" },
    }));
    await ui("flag", "--set", "features.showToolCalls=false");
    await ui("type", "--name", "Message Pepper", "--text", "Please have Engineer check the CSV export and report back");
    await ui("press", "--keys", "Enter");
    await expect.poll(snapshot, { timeout: 15_000 }).toContain("Teammates working");
    const waiting = (await api("/api/bots?messages=0")).bots.find((bot: any) => bot.id === info.botId);
    expect(waiting).toMatchObject({ busy: false, waitingForTeammates: true });
    const controls = (await ui("snapshot")).refs as Record<string, { role: string; name: string }>;
    expect(Object.values(controls).some(control => control.role === "textbox" && control.name === "Message Pepper")).toBe(true);
    await ui("screenshot", "--out", info.logPath + ".teammates-working.png");
    writeFileSync(gateFile, "complete fixture work");
    await ui("wait-settle", "--timeout", "60");
    await expect.poll(snapshot, { timeout: 15_000 }).toContain("Engineer checked the fixture CSV export");
    expect(await snapshot()).toContain("Sent to Engineer");
    const state = await api("/api/bots");
    const parent = state.bots.find((bot: any) => bot.id === info.botId);
    const receipt = parent.messages.find((message: any) => message.tool?.name === "Sent to Engineer");
    expect(receipt.threadRef.botId).toBe(lead.id);
    expect(receipt.threadRef.threadId).not.toBe(lead.threadId);
    const screenshot = info.logPath + ".direct-coordination.png";
    await ui("screenshot", "--out", screenshot);
    await click("Sent to Engineer");
    await expect.poll(snapshot, { timeout: 15_000 }).toContain("CSV export checked in my separate task");
    const selected = (await api("/api/bots")).bots.find((bot: any) => bot.id === lead.id);
    expect(selected.threadId).toBe(receipt.threadRef.threadId);
    const evidence = { source: parent.messages, receipt, selectedThread: selected.threadId, final: await snapshot(), screenshot };
    writeFileSync(info.logPath + ".direct-coordination.json", JSON.stringify(evidence, null, 2));
    console.log("Direct coordination UI evidence:", info.logPath + ".direct-coordination.json");
  } finally {
    await waitForExit(child, { signal: "SIGINT", graceMs: 30_000 });
    await removeTempDir(temporary);
  }
}, 240_000);

(enabled ? it : it.skip)("opens both sides of a one-way send from their canonical links", async () => {
  const temporary = mkdtempSync(join(tmpdir(), "omb-handoff-ui-plan-"));
  const planPath = join(temporary, "plan.json");
  writeFileSync(planPath, "{}");
  const child = spawn(process.execPath, ["--experimental-strip-types", "scripts/control-omb.ts", "ui", "launch"], {
    cwd: ROOT, env: { ...process.env, FAKE_CLAUDE_ROOM_PLAN: planPath }, stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  let error = "";
  child.stdout.on("data", chunk => { output += String(chunk); });
  child.stderr.on("data", chunk => { error += String(chunk); });
  child.on("error", caught => { error += caught.message; });
  let info: { ui: string; url: string; botId: string; logPath: string };
  try {
    await expect.poll(() => {
      if (child.exitCode !== null || child.signalCode !== null) throw new Error(error);
      try { info = JSON.parse(output); return Boolean(info.ui); } catch { return false; }
    }, { timeout: 180_000, interval: 250 }).toBe(true);
    const api = async (path: string, body?: unknown, method = "POST") => {
      const response = await fetch(info.url + path, body === undefined ? {} : {
        method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(JSON.stringify(result));
      return result;
    };
    const ui = (verb: string, ...args: string[]) => runControlOmb(["ui", verb, "--ui", info.ui, ...args]) as Promise<any>;
    const snapshot = async () => (await ui("snapshot")) as { snapshot: string; refs: Record<string, { role: string; name: string }> };
    const click = async (name: string) => {
      const current = await snapshot();
      const match = Object.entries(current.refs).find(([, entry]) => entry.role === "button" && entry.name.endsWith(name));
      expect(match).toBeDefined();
      await ui("click", "--ref", "@" + match![0]);
    };
    const recipient = (await api("/api/bots", { name: "Engineer", title: "Implementation", section: "" })).bot;
    writeFileSync(planPath, JSON.stringify({
      [info.botId]: { steps: [{ tool: "send_to_bot", arguments: {
        bot_id: recipient.id, request_key: "release-owner", title: "Release owner", brief: "Own the fixture release.",
      } }], reply: "Ownership transferred" },
      [recipient.id]: { reply: "I own the fixture release now." },
    }));
    await ui("flag", "--set", "features.showToolCalls=false");
    await ui("type", "--name", "Message Pepper", "--text", "Hand the fixture release to Engineer");
    await ui("press", "--keys", "Enter");
    await ui("wait-settle", "--timeout", "60");
    await expect.poll(async () => (await snapshot()).snapshot, { timeout: 15_000 }).toContain("Opened thread #Release owner on Engineer");
    const state = await api("/api/bots");
    const source = state.bots.find((bot: any) => bot.id === info.botId);
    const handed = state.bots.find((bot: any) => bot.id === recipient.id).tasks.find((task: any) => task.title === "Release owner");
    expect(handed.threadId).toBeTruthy();
    await ui("screenshot", "--out", info.logPath + ".handoff-source.png");
    await click("Opened thread #Release owner on Engineer");
    await expect.poll(async () => (await snapshot()).snapshot, { timeout: 15_000 }).toContain("I own the fixture release now.");
    expect((await snapshot()).snapshot).toContain("Source conversation");
    await ui("screenshot", "--out", info.logPath + ".handoff-recipient.png");
    await click("Source conversation");
    await expect.poll(async () => (await snapshot()).snapshot, { timeout: 15_000 }).toContain("Hand the fixture release to Engineer");
    const selectedSource = (await api("/api/bots")).bots.find((bot: any) => bot.id === info.botId);
    expect(selectedSource.threadId).toBe(source.threadId);
    writeFileSync(info.logPath + ".handoff.json", JSON.stringify({
      sourceThreadId: source.threadId, recipientThreadId: handed.threadId,
      sourceScreenshot: info.logPath + ".handoff-source.png", recipientScreenshot: info.logPath + ".handoff-recipient.png",
    }, null, 2));
    console.log("Handoff UI evidence:", info.logPath + ".handoff.json");
  } finally {
    await waitForExit(child, { signal: "SIGINT", graceMs: 30_000 });
    await removeTempDir(temporary);
  }
}, 240_000);
