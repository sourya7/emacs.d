import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";

type Mode = "immediate" | "delayed" | "fail" | "external-window";
type Params = {
  path: string;
  mode: Mode;
  content: string;
  startReleasePath?: string;
  endReleasePath?: string;
};

const preflightText = new Map<string, string>();

async function waitForRelease(path: string, signal?: AbortSignal): Promise<void> {
  const deadline = Date.now() + 8000;
  while (!existsSync(path)) {
    if (Date.now() >= deadline) {
      throw new Error(`Timed out waiting for test release: ${path}`);
    }
    await delay(10, undefined, { signal });
  }
}

/**
 * Real-Pi fixture for measuring RPC observation around file mutations.
 *
 * The tool_call hook records the state at Pi's pre-execution interception
 * point.  Explicit release files hold the delayed tool before mutation and
 * the external-window tool before completion; no scheduling window is assumed.
 */
export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event, ctx) => {
    if (event.toolName !== "pichat_timing_mutate") return;
    const input = event.input as Params;
    const path = resolve(ctx.cwd, input.path);
    preflightText.set(event.toolCallId, readFileSync(path, "utf8"));
  });

  pi.registerTool({
    name: "pichat_timing_mutate",
    label: "PiChat Timing Mutation",
    description: "Deterministic file mutation fixture for PiChat integration tests",
    parameters: Type.Object({
      path: Type.String(),
      mode: StringEnum(
        ["immediate", "delayed", "fail", "external-window"] as const,
      ),
      content: Type.String(),
      startReleasePath: Type.Optional(Type.String()),
      endReleasePath: Type.Optional(Type.String()),
    }),
    async execute(toolCallId, params: Params, signal, _onUpdate, ctx) {
      const path = resolve(ctx.cwd, params.path);
      const before = preflightText.get(toolCallId);

      if (params.mode === "delayed" || params.mode === "external-window") {
        if (!params.startReleasePath) throw new Error("Missing start release path");
        await waitForRelease(resolve(ctx.cwd, params.startReleasePath), signal);
      }
      if (params.mode === "fail") {
        throw new Error("intentional mutation failure before write");
      }

      writeFileSync(path, params.content, "utf8");
      if (params.mode === "external-window") {
        if (!params.endReleasePath) throw new Error("Missing end release path");
        await waitForRelease(resolve(ctx.cwd, params.endReleasePath), signal);
      }

      return {
        content: [{ type: "text" as const, text: `wrote:${params.content}` }],
        details: { preflightText: before },
      };
    },
  });
}
