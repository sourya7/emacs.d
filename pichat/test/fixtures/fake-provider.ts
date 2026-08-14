import { readFileSync, writeFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type Context,
  type Model,
  type SimpleStreamOptions,
  type ToolCall,
  type Usage,
} from "@earendil-works/pi-ai";

type FakeTurn = {
  text?: string | string[];
  toolCall?: { id?: string; name: string; arguments?: Record<string, unknown> };
  error?: string;
  delayMs?: number;
  expectContextIncludes?: string | string[];
  expectTool?: { name: string; parameters?: Record<string, unknown> };
  expectToolAbsent?: string;
  expectToolResultError?: string;
};

type FakeScript = {
  turns?: FakeTurn[];
};

const provider = "pichat-fake";
const modelId = "pichat-fake";
const reasoningModelId = "pichat-fake-reasoning";
const api = "pichat-fake-api";

let script: FakeScript = loadScript();
let turnIndex = 0;
let unexpectedCalls = 0;

function loadScript(): FakeScript {
  const inline = process.env.PICHAT_FAKE_PROVIDER_SCRIPT_JSON;
  if (inline) return JSON.parse(inline) as FakeScript;

  const file = process.env.PICHAT_FAKE_PROVIDER_SCRIPT;
  if (file) return JSON.parse(readFileSync(file, "utf8")) as FakeScript;

  return { turns: [{ text: "hello" }] };
}

function writeStatus(extra: Record<string, unknown> = {}) {
  const file = process.env.PICHAT_FAKE_PROVIDER_STATUS;
  if (!file) return;
  writeFileSync(
    file,
    JSON.stringify(
      {
        turnIndex,
        totalTurns: script.turns?.length ?? 0,
        consumedAll: turnIndex === (script.turns?.length ?? 0),
        unexpectedCalls,
        ...extra,
      },
      null,
      2,
    ),
  );
}

function usage(): Usage {
  return {
    input: 1,
    output: 1,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 2,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
}

function makeMessage(model: Model<any>): AssistantMessage {
  return {
    role: "assistant",
    content: [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: usage(),
    stopReason: "stop",
    timestamp: Date.now(),
  };
}

function contextString(context: Context): string {
  try {
    return JSON.stringify(context);
  } catch (error) {
    return String(context);
  }
}

function requireExpectedContext(turn: FakeTurn, context: Context) {
  const expected = turn.expectContextIncludes;
  const haystack = contextString(context);
  if (expected) {
    const needles = Array.isArray(expected) ? expected : [expected];
    for (const needle of needles) {
      if (!haystack.includes(needle)) {
        throw new Error(`fake provider expected context to include ${JSON.stringify(needle)}`);
      }
    }
  }

  if (turn.expectTool) {
    const tool = context.tools?.find((candidate) => candidate.name === turn.expectTool?.name);
    if (!tool) throw new Error(`fake provider expected tool ${turn.expectTool.name}`);
    if (turn.expectTool.parameters && !isDeepStrictEqual(tool.parameters, turn.expectTool.parameters)) {
      throw new Error(
        `fake provider expected schema ${JSON.stringify(turn.expectTool.parameters)}, got ${JSON.stringify(tool.parameters)}`,
      );
    }
  }

  if (turn.expectToolAbsent && context.tools?.some((tool) => tool.name === turn.expectToolAbsent)) {
    throw new Error(`fake provider expected tool ${turn.expectToolAbsent} to be inactive`);
  }

  if (turn.expectToolResultError) {
    const message = context.messages.find((candidate: any) =>
      candidate?.role === "toolResult" &&
      candidate?.toolName === turn.expectToolResultError &&
      candidate?.isError === true,
    );
    if (!message) throw new Error(`fake provider expected failed tool result ${turn.expectToolResultError}`);
  }
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    const timer = setTimeout(resolve, ms);
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

function asTextChunks(text: string | string[] | undefined): string[] {
  if (Array.isArray(text)) return text;
  if (typeof text === "string") return [text];
  return ["hello"];
}

function streamFake(model: Model<any>, context: Context, options?: SimpleStreamOptions) {
  const stream = createAssistantMessageEventStream();

  void (async () => {
    const output = makeMessage(model);

    try {
      const turn = script.turns?.[turnIndex];
      if (!turn) {
        unexpectedCalls++;
        throw new Error(`fake provider received unexpected model call ${turnIndex + 1}`);
      }
      turnIndex++;
      writeStatus({ lastContext: contextString(context) });

      requireExpectedContext(turn, context);
      await sleep(turn.delayMs ?? 0, options?.signal);

      stream.push({ type: "start", partial: output });

      if (turn.error) {
        output.stopReason = options?.signal?.aborted ? "aborted" : "error";
        output.errorMessage = turn.error;
        stream.push({ type: "error", reason: output.stopReason, error: output });
        stream.end(output);
        writeStatus();
        return;
      }

      if (turn.toolCall) {
        const toolCall: ToolCall = {
          type: "toolCall",
          id: turn.toolCall.id ?? `pichat-fake-tool-${turnIndex}`,
          name: turn.toolCall.name,
          arguments: turn.toolCall.arguments ?? {},
        };
        output.content.push(toolCall);
        output.stopReason = "toolUse";
        const contentIndex = output.content.length - 1;
        stream.push({ type: "toolcall_start", contentIndex, partial: output });
        stream.push({
          type: "toolcall_delta",
          contentIndex,
          delta: JSON.stringify(toolCall.arguments),
          partial: output,
        });
        stream.push({ type: "toolcall_end", contentIndex, toolCall, partial: output });
        stream.push({ type: "done", reason: "toolUse", message: output });
        stream.end(output);
        writeStatus();
        return;
      }

      output.content.push({ type: "text", text: "" });
      const contentIndex = output.content.length - 1;
      stream.push({ type: "text_start", contentIndex, partial: output });
      const block = output.content[contentIndex];
      if (block.type !== "text") throw new Error("fake provider text block invariant failed");
      for (const delta of asTextChunks(turn.text)) {
        await sleep(turn.delayMs ?? 0, options?.signal);
        block.text += delta;
        stream.push({ type: "text_delta", contentIndex, delta, partial: output });
      }
      stream.push({ type: "text_end", contentIndex, content: block.text, partial: output });
      output.stopReason = options?.signal?.aborted ? "aborted" : "stop";
      stream.push({ type: "done", reason: output.stopReason, message: output });
      stream.end(output);
      writeStatus();
    } catch (error) {
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : String(error);
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end(output);
      writeStatus({ error: output.errorMessage });
    }
  })();

  return stream;
}

export default function (pi: ExtensionAPI) {
  writeStatus();
  pi.registerProvider(provider, {
    name: "PiChat Fake Provider",
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "pichat-test",
    api,
    models: [
      {
        id: modelId,
        name: "PiChat Fake Model",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000,
        maxTokens: 4096,
      },
      {
        id: reasoningModelId,
        name: "PiChat Fake Reasoning Model",
        reasoning: true,
        thinkingLevelMap: {
          minimal: null,
          low: "low",
          medium: null,
          high: "high",
          xhigh: null,
          max: "max",
        },
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128000,
        maxTokens: 4096,
      },
    ],
    streamSimple: streamFake,
  });
}
