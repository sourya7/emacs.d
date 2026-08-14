import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";

type Mode = "immediate" | "delayed" | "fail" | "external-window";
type Params = {
  path: string;
  mode: Mode;
  content: string;
  delayMs?: number;
  postDelayMs?: number;
};

const preflightText = new Map<string, string>();

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolvePromise, reject) => {
    if (signal?.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    const timer = setTimeout(resolvePromise, ms);
    signal?.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        reject(new DOMException("Aborted", "AbortError"));
      },
      { once: true },
    );
  });
}

/**
 * Real-Pi fixture for measuring RPC observation around file mutations.
 *
 * The tool_call hook records the state at Pi's pre-execution interception
 * point.  The tool modes then provide immediate, delayed, failed, and
 * post-mutation windows for an independent RPC client to observe.
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
      delayMs: Type.Optional(Type.Number()),
      postDelayMs: Type.Optional(Type.Number()),
    }),
    async execute(toolCallId, params: Params, signal, _onUpdate, ctx) {
      const path = resolve(ctx.cwd, params.path);
      const before = preflightText.get(toolCallId);

      if (
        params.mode === "delayed" ||
        params.mode === "external-window" ||
        params.mode === "fail"
      ) {
        await sleep(params.delayMs ?? 200, signal);
      }
      if (params.mode === "fail") {
        throw new Error("intentional mutation failure before write");
      }

      writeFileSync(path, params.content, "utf8");
      if (params.mode === "external-window") {
        await sleep(params.postDelayMs ?? 500, signal);
      }

      return {
        content: [{ type: "text" as const, text: `wrote:${params.content}` }],
        details: { preflightText: before },
      };
    },
  });
}
