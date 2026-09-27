// A teammate's run crashes; nobody is at the keyboard. The Chief of Staff
// is told in its own "Team incidents" thread, with a link to the broken
// thread, and can resume it from there — the person's phone shows one
// place to read. Pinned against the real server with the fake CLI failing
// exactly one bot's run.
import { spawn, type ChildProcess } from "node:child_process";
import { closeSync, existsSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { expect, it } from "vitest";
import { launchVerificationServer, runControlOmb, verificationServerEnvironment } from "../scripts/control-omb.ts";
import { waitForExit } from "./testing/cleanup.ts";
import { openSse } from "./testing/sse.ts";

it("reports a crashed run to the Chief, who retries it from the incidents thread", async () => {
  const fixture = await launchVerificationServer();
  const { url, dataDir } = fixture.info;
  const api = async (method: string, path: string, body?: unknown, token?: string, expectedStatus = 200) => {
    const response = await fetch(url + path, {
      method,
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : { origin: url }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const value = await response.json() as any;
    expect(response.status, `${method} ${path}: ${JSON.stringify(value)}`).toBe(expectedStatus);
    return value;
  };
  const control = (args: string[]) => runControlOmb([...args, "--url", url]) as Promise<any>;
  const file = (threadId: string, extension: string) => join(dataDir, `${threadId}.${extension}`);
  const dump = async (threadId: string) => {
    await expect.poll(() => existsSync(file(threadId, "json")), { timeout: 20_000 }).toBe(true);
    return JSON.parse(readFileSync(file(threadId, "json"), "utf8"));
  };
  const messages = async (threadId: string) => (await api("GET", `/api/threads/${threadId}/messages?limit=100`)).messages as any[];
  const botsNow = async () => (await api("GET", "/api/bots")).bots as any[];
  try {
    const chief = (await control(["new-bot", "--name", "Clive", "--section", "Ops"])).bot;
    await api("PATCH", `/api/bots/${chief.id}`, { chiefOfStaff: true });
    const ada = (await control(["new-bot", "--name", "Ada", "--section", "Ops"])).bot;
    const fixedFlag = join(dataDir, "ada-fixed");

    // Ada's own thread crashes before any result until the flag appears;
    // the Chief's turns are held open by a gate so their token stays live;
    // every turn dumps to <thread>.json.
    const wrapper = join(dataDir, "incident-cli.mjs");
    writeFileSync(wrapper, [
      "#!/usr/bin/env node",
      'import { existsSync, readFileSync } from "node:fs";',
      'import { join } from "node:path";',
      'const at = process.argv.indexOf("--mcp-config");',
      'const thread = at < 0 ? "probe" : JSON.parse(readFileSync(process.argv[at + 1], "utf8")).mcpServers?.agents?.env?.OMB_THREAD_ID ?? "probe";',
      // Ada's run crashes until the flag appears; every other real turn is
      // held open by a gate so tokens stay live and timing is deterministic.
      `process.env.FAKE_CLAUDE_MODE = thread === "probe" ? "happy" : thread === ${JSON.stringify(ada.activeTaskId)} && !existsSync(${JSON.stringify(fixedFlag)}) ? "exit-early" : "slow";`,
      `process.env.FAKE_CLAUDE_SLOW_FINISH_GATE = join(${JSON.stringify(dataDir)}, thread + ".gate");`,
      `process.env.FAKE_CLAUDE_DUMP = join(${JSON.stringify(dataDir)}, thread + ".json");`,
      `await import(${JSON.stringify(pathToFileURL(join(process.cwd(), "server/testing/fake-claude-cli.ts")).href)});`,
    ].join("\n"), { mode: 0o700 });
    await api("PATCH", "/api/instances/claude", { cli: wrapper });

    // The person asks Ada for something and walks away; Ada's run dies.
    await control(["send", "--bot", ada.id, "--text", "Reconcile the September invoices."]);
    await expect.poll(async () => (await messages(ada.activeTaskId)).some((m) => m.kind === "activity" && /exit_before_result|error/i.test(m.tool?.name ?? "")), { timeout: 20_000 }).toBe(true);

    // The Chief gets a "Team incidents" thread with the chip and a link to Ada's thread…
    await expect.poll(async () => (await botsNow()).find((b) => b.id === chief.id)?.tasks?.some((t: any) => t.title === "Team incidents"), { timeout: 20_000 }).toBe(true);
    const incidents = (await botsNow()).find((b) => b.id === chief.id).tasks.find((t: any) => t.title === "Team incidents");
    await expect.poll(async () => (await messages(incidents.threadId)).some((m) =>
      m.kind === "activity" && m.tool?.name === 'Incident: Ada\'s run in its thread #Reconcile the September invoices. failed: "exit_before_result"' && m.threadRef?.threadId === ada.activeTaskId && m.threadRef?.botId === ada.id,
    ), { timeout: 10_000 }).toBe(true);
    // …and a turn of its own carrying the report, marked as not from the person.
    const chiefRun = await dump(incidents.threadId);
    const prompt = JSON.stringify(chiefRun.prompt);
    expect(prompt).toContain("[Incident report from OpenMausBot — not from the person.");
    expect(prompt).toContain("Ada's run in its thread #Reconcile the September invoices. failed");
    expect(prompt).toContain("Reconcile the September invoices.");
    expect(prompt).toContain(`retry_thread with bot_id \\"${ada.id}\\" and thread_id \\"${ada.activeTaskId}\\"`);
    expect(chiefRun.systemPrompt).toContain("Team incidents");
    expect(chiefRun.systemPrompt).toContain("retry_thread");
    const reportLine = (await messages(incidents.threadId)).find((m) => m.role === "user" && /Incident report/.test(m.text ?? ""));
    expect(reportLine?.peerAsk).toMatchObject({ botId: ada.id, name: "Ada", unattended: true });

    // From that turn the Chief resumes Ada's thread; the cause is fixed by now.
    const token = chiefRun.mcpConfig.mcpServers.agents.env.OMB_COMMS_TOKEN;
    writeFileSync(fixedFlag, "fixed");
    const retry = { fromBotId: chief.id, fromThreadId: incidents.threadId, toBotId: ada.id, toThreadId: ada.activeTaskId };
    expect(await api("POST", "/api/internal/retry-thread", { ...retry, note: "The service was down; try again." }, token, 200)).toMatchObject({ started: true });
    // while it runs a second retry is refused; so is a thread that does not exist
    expect((await api("POST", "/api/internal/retry-thread", retry, token, 409)).error).toMatch(/still running/);
    expect((await api("POST", "/api/internal/retry-thread", { ...retry, toThreadId: "no-such-thread" }, token, 404)).error).toMatch(/no such thread/);
    writeFileSync(file(incidents.threadId, "gate"), "finish");
    expect((await control(["wait", "--bot", chief.id, "--task", incidents.threadId, "--timeout", "30"])).status).toBe("settled");

    // The retry carried the Chief's name and reason; Ada finished this time.
    writeFileSync(file(ada.activeTaskId, "gate"), "finish");
    await expect.poll(async () => (await control(["wait", "--bot", ada.id, "--timeout", "30"])).status, { timeout: 40_000 }).toBe("settled");
    const adaMessages = await messages(ada.activeTaskId);
    const retryLine = adaMessages.find((m) => m.role === "user" && /Retry requested by Clive, your Chief of Staff/.test(m.text ?? ""));
    expect(retryLine?.text).toContain("Note from Clive: The service was down; try again.");
    expect(retryLine?.peerAsk).toMatchObject({ botId: chief.id, name: "Clive" });
    expect(adaMessages.filter((m) => m.role === "bot" && m.kind === "text" && m.text).length).toBeGreaterThan(0);
    expect((await messages(incidents.threadId)).some((m) => m.kind === "activity" && (m.tool?.name ?? "").startsWith("Retried Ada's thread #") && m.threadRef?.threadId === ada.activeTaskId)).toBe(true);

    // Only a Chief may retry: Ada's own token is refused.
    const adaRun = JSON.parse(readFileSync(file(ada.activeTaskId, "json"), "utf8"));
    const adaToken = adaRun.mcpConfig.mcpServers.agents.env.OMB_COMMS_TOKEN;
    const refused = await fetch(`${url}/api/internal/retry-thread`, {
      method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${adaToken}` },
      body: JSON.stringify({ fromBotId: ada.id, fromThreadId: ada.activeTaskId, toBotId: chief.id, toThreadId: incidents.threadId }),
    });
    expect([401, 403]).toContain(refused.status);
  } finally {
    await fixture.close();
  }
}, 150_000);

it("keeps every managed-team failure local when the selected Chief opts out, then resumes future incidents", async () => {
  const fixture = await launchVerificationServer();
  const { url, dataDir, logPath } = fixture.info;
  let restarted: ChildProcess | undefined;
  const api = async (method: string, path: string, body?: unknown, expectedStatus = 200) => {
    const response = await fetch(url + path, {
      method,
      headers: { "content-type": "application/json", origin: url },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const value = await response.json() as any;
    expect(response.status, `${method} ${path}: ${JSON.stringify(value)}`).toBe(expectedStatus);
    return value;
  };
  const control = (args: string[]) => runControlOmb([...args, "--url", url]) as Promise<any>;
  const botsNow = async () => (await api("GET", "/api/bots")).bots as any[];
  const messages = async (threadId: string) => (await api("GET", `/api/threads/${threadId}/messages?limit=100`)).messages as any[];
  const modeFile = join(dataDir, "incident-modes.json");
  const invocationLog = join(dataDir, "incident-invocations.jsonl");
  const setMode = (botId: string, mode: string) => writeFileSync(modeFile, JSON.stringify({ [botId]: mode }));
  const errorCount = async (threadId: string) => (await messages(threadId)).filter((message) =>
    message.kind === "activity" && message.tool?.ok === false && /error|failed|activity/i.test(message.tool?.name ?? "")
  ).length;
  const waitForNewError = async (threadId: string, before: number, pattern: RegExp) => {
    await expect.poll(async () => {
      const errors = (await messages(threadId)).filter((message) => message.kind === "activity" && message.tool?.ok === false);
      return errors.length > before ? errors.at(-1)?.tool?.name ?? "" : "";
    }, { timeout: 140_000, interval: 150 }).toMatch(pattern);
  };
  try {
    const worker = (await control(["new-bot", "--name", "Ada", "--section", "Research"])).bot;
    const fallback = (await control(["new-bot", "--name", "Fallback", "--section", "Sales"])).bot;
    await api("PATCH", `/api/bots/${fallback.id}`, { chiefOfStaff: true });
    await api("PATCH", `/api/bots/${fallback.id}`, { managedSections: ["Research"], acknowledgePeerScope: true });
    const chief = (await control(["new-bot", "--name", "Quiet Chief", "--section", "Ops"])).bot;
    await api("PATCH", `/api/bots/${chief.id}`, { chiefOfStaff: true });
    await api("PATCH", `/api/bots/${chief.id}`, {
      managedSections: ["Research"],
      acknowledgePeerScope: true,
      automaticTeamIncidents: false,
    });
    const unrelated = (await control(["new-bot", "--name", "Unrelated", "--section", "Elsewhere"])).bot;

    const wrapper = join(dataDir, "incident-toggle-cli.mjs");
    writeFileSync(wrapper, [
      "#!/usr/bin/env node",
      'import { appendFileSync, existsSync, readFileSync } from "node:fs";',
      "const at = process.argv.indexOf('--mcp-config');",
      "const integration = at < 0 ? {} : JSON.parse(readFileSync(process.argv[at + 1], 'utf8')).mcpServers?.agents?.env ?? {};",
      `const modes = existsSync(${JSON.stringify(modeFile)}) ? JSON.parse(readFileSync(${JSON.stringify(modeFile)}, "utf8")) : {};`,
      "const mode = modes[integration.OMB_BOT_ID] ?? 'happy';",
      `appendFileSync(${JSON.stringify(invocationLog)}, JSON.stringify({ botId: integration.OMB_BOT_ID, threadId: integration.OMB_THREAD_ID, mode }) + "\\n");`,
      "process.env.FAKE_CLAUDE_MODE = mode;",
      `await import(${JSON.stringify(pathToFileURL(join(process.cwd(), "server/testing/fake-claude-cli.ts")).href)});`,
    ].join("\n"), { mode: 0o700 });
    await api("PATCH", "/api/instances/claude", { cli: wrapper });

    // The explicit false survives a real server restart before any failure.
    await waitForExit(fixture.child, { signal: "SIGTERM" });
    const env = verificationServerEnvironment(process.env, dataDir, Number(new URL(url).port));
    env.OMB_TURN_STALL_MS = "60000";
    const log = openSync(logPath, "a", 0o600);
    restarted = spawn(process.execPath, ["--experimental-strip-types", join(process.cwd(), "server/index.ts")], {
      cwd: process.cwd(), env, stdio: ["ignore", log, log],
    });
    closeSync(log);
    await expect.poll(async () => {
      if (restarted?.exitCode !== null) throw new Error(readFileSync(logPath, "utf8"));
      return fetch(`${url}/api/health`).then((response) => response.ok).catch(() => false);
    }, { timeout: 20_000, interval: 150 }).toBe(true);
    expect((await botsNow()).find((bot) => bot.id === chief.id)).toMatchObject({ automaticTeamIncidents: false });

    const stream = await openSse(`${url}/api/events`);
    try {
      await stream.until((frame) => frame.kind === "hello");

      setMode(worker.id, "exit-early");
      let before = await errorCount(worker.activeTaskId);
      await control(["send", "--bot", worker.id, "--text", "Fail normally."]);
      await waitForNewError(worker.activeTaskId, before, /exit_before_result|error/i);

      // A missing CLI exercises the dispatch/could-not-start notification path.
      await api("PATCH", "/api/instances/claude", { cli: join(dataDir, "missing-cli") });
      before = await errorCount(worker.activeTaskId);
      await control(["send", "--bot", worker.id, "--text", "Do not start."]);
      await waitForNewError(worker.activeTaskId, before, /couldn't start|unavailable|error/i);
      await api("PATCH", "/api/instances/claude", { cli: wrapper });

      const routine = (await api("POST", "/api/routines", {
        name: "Broken digest", prompt: "Fail this routine.", botId: worker.id, enabled: false,
        schedule: { type: "once", at: Date.now() + 3_600_000 },
      }, 201)).routine;
      const run = (await api("POST", `/api/routines/${routine.id}/run`, undefined, 201)).run;
      await expect.poll(async () => (await api("GET", "/api/routines")).runs.find((candidate: any) => candidate.id === run.id)?.status,
        { timeout: 30_000, interval: 150 }).toBe("failed");
      const failedRun = (await api("GET", "/api/routines")).runs.find((candidate: any) => candidate.id === run.id);
      expect((await messages(failedRun.threadId)).some((message) => message.kind === "activity" && message.tool?.ok === false)).toBe(true);

      setMode(worker.id, "hang");
      before = await errorCount(worker.activeTaskId);
      await control(["send", "--bot", worker.id, "--text", "Stall this job."]);
      await waitForNewError(worker.activeTaskId, before, /no activity.*stopped/i);

      // Unrelated notifications are unchanged.
      setMode(unrelated.id, "happy");
      await control(["send", "--bot", unrelated.id, "--text", "Finish normally."]);
      await stream.until((frame) => frame.kind === "notify" && frame.notification?.kind === "done" && frame.notification?.botId === unrelated.id, 20_000);

      // A bot frame is an ordering barrier for every failure notification above.
      await api("PATCH", `/api/bots/${worker.id}`, { description: "Failures observed" });
      await stream.until((frame) => frame.kind === "bot" && frame.bot?.id === worker.id && frame.bot?.description === "Failures observed");
      expect(stream.frames.filter((frame) => frame.kind === "notify" && frame.notification?.botId === worker.id)).toEqual([]);
      for (const candidate of [chief, fallback]) {
        expect((await botsNow()).find((bot) => bot.id === candidate.id).tasks.some((task: any) => task.title === "Team incidents")).toBe(false);
      }
      const invocations = existsSync(invocationLog)
        ? readFileSync(invocationLog, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line))
        : [];
      expect(invocations.some((entry) => entry.botId === chief.id || entry.botId === fallback.id)).toBe(false);

      // Re-enabling restores the existing incident route for future failures.
      await api("PATCH", `/api/bots/${chief.id}`, { automaticTeamIncidents: true });
      setMode(worker.id, "exit-early");
      before = await errorCount(worker.activeTaskId);
      await control(["send", "--bot", worker.id, "--text", "Fail after re-enabling."]);
      await waitForNewError(worker.activeTaskId, before, /exit_before_result|error/i);
      await expect.poll(async () => (await botsNow()).find((bot) => bot.id === chief.id)?.tasks.some((task: any) => task.title === "Team incidents"),
        { timeout: 20_000, interval: 150 }).toBe(true);
      expect((await botsNow()).find((bot) => bot.id === fallback.id).tasks.some((task: any) => task.title === "Team incidents")).toBe(false);
    } finally {
      stream.close();
    }
  } finally {
    if (restarted) await waitForExit(restarted, { signal: "SIGTERM" });
    await fixture.close();
  }
}, 240_000);
