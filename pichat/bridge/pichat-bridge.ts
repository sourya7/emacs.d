import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type, type TSchema } from "typebox";

type PiChatToolDef = { name: string; label?: string; description?: string; instructions?: string; parameters?: unknown; mutating?: boolean };
type PiChatToolsResponse = { protocolVersion?: number; tools?: PiChatToolDef[] };
type SystemPromptOptions = { selectedTools: string[] };

const PROTOCOL_VERSION = 1;
const STATUS_KEY = "pichat-bridge";

const TOOLS_REQUEST_TITLE = "__pichat_tools_request__";
const TOOL_CALL_TITLE = "__pichat_tool_call__";

export default function (pi: ExtensionAPI) {
	const registeredTools = new Set<string>();
	const toolFingerprints = new Map<string, string>();

	function validTool(tool: unknown): tool is PiChatToolDef {
		if (!tool || typeof tool !== "object") return false;
		const candidate = tool as PiChatToolDef;
		return typeof candidate.name === "string" && /^[A-Za-z0-9_-]+$/.test(candidate.name)
			&& (candidate.label === undefined || typeof candidate.label === "string")
			&& (candidate.description === undefined || typeof candidate.description === "string")
			&& (candidate.instructions === undefined || (typeof candidate.instructions === "string" && candidate.instructions.trim().length > 0))
			&& (candidate.parameters === undefined || (!!candidate.parameters && typeof candidate.parameters === "object" && !Array.isArray(candidate.parameters)))
			&& (candidate.mutating === undefined || typeof candidate.mutating === "boolean");
	}

	function schemaForTool(tool: PiChatToolDef): TSchema {
		if (tool.parameters && typeof tool.parameters === "object") {
			return Type.Unsafe(tool.parameters as TSchema);
		}
		return Type.Any();
	}

	// Pi 1.5.1 RPC `ui.editor` ignores options, so an aborted turn would wait
	// for Emacs forever.  Stop waiting on abort; Emacs withdraws the queued
	// approval when the turn settles and never runs the tool.
	function untilAborted<T>(promise: Promise<T>, signal: AbortSignal | undefined): Promise<T> {
		if (!signal) return promise;
		if (signal.aborted) return Promise.reject(new Error("Aborted before Emacs answered"));
		return new Promise<T>((resolve, reject) => {
			const onAbort = () => reject(new Error("Aborted before Emacs answered"));
			signal.addEventListener("abort", onAbort, { once: true });
			promise.then(
				(value) => { signal.removeEventListener("abort", onAbort); resolve(value); },
				(err) => { signal.removeEventListener("abort", onAbort); reject(err); },
			);
		});
	}

	function textFromToolResult(result: any): string {
		const content = result?.content;
		if (Array.isArray(content)) {
			return content
				.map((part) => typeof part?.text === "string" ? part.text : JSON.stringify(part))
				.join("\n");
		}
		return typeof result === "string" ? result : JSON.stringify(result);
	}

	async function syncTools(ctx: any, systemPromptOptions?: SystemPromptOptions) {
		// Only PiChat loads this bridge, so ask for definitions directly; the
		// reply's protocolVersion is the compatibility check.  Without a UI
		// (print mode) nobody could answer.
		if (!ctx.hasUI) return;
		ctx.ui.setStatus(STATUS_KEY, "synchronizing");
		let raw: string | undefined;
		try {
			raw = await ctx.ui.editor(TOOLS_REQUEST_TITLE, JSON.stringify({ protocolVersion: PROTOCOL_VERSION }));
		} catch (err) {
			ctx.ui.setStatus(STATUS_KEY, `sync-error:${err instanceof Error ? err.message : String(err)}`);
			return;
		}
		if (!raw) {
			ctx.ui.setStatus(STATUS_KEY, "sync-error:no-response");
			return;
		}
		let response: PiChatToolsResponse;
		try { response = JSON.parse(raw) as PiChatToolsResponse; } catch {
			ctx.ui.setStatus(STATUS_KEY, "sync-error:invalid-json");
			return;
		}
		// Fail closed: a host speaking another version declares no tools here.
		if (response?.protocolVersion !== PROTOCOL_VERSION) {
			ctx.ui.setStatus(STATUS_KEY, `incompatible-protocol:${String(response?.protocolVersion)}`);
			return;
		}
		if (!Array.isArray(response.tools)) {
			ctx.ui.setStatus(STATUS_KEY, "sync-error:invalid-envelope");
			return;
		}
		const tools = response.tools.filter(validTool);
		if (tools.length !== response.tools.length) {
			ctx.ui.setStatus(STATUS_KEY, "sync-error:invalid-tool-definition");
			return;
		}
		const nextNames = new Set(tools.map((tool) => tool.name));
		for (const tool of tools) {
			const fingerprint = JSON.stringify(tool);
			if (toolFingerprints.get(tool.name) === fingerprint) continue;
			registeredTools.add(tool.name);
			toolFingerprints.set(tool.name, fingerprint);
			pi.registerTool({
				name: tool.name,
				label: tool.label ?? tool.name,
				description: tool.description ?? "Emacs-defined PiChat tool",
				promptSnippet: tool.description ?? `Call Emacs tool ${tool.name}`,
				...(tool.instructions === undefined ? {} : { promptGuidelines: [tool.instructions] }),
				parameters: schemaForTool(tool),
				async execute(_toolCallId, params, signal, _onUpdate, toolCtx) {
					if (signal?.aborted) throw new Error("Aborted before Emacs answered");
					const resultRaw = await untilAborted(
						toolCtx.ui.editor(TOOL_CALL_TITLE, JSON.stringify({ protocolVersion: PROTOCOL_VERSION, name: tool.name, params })),
						signal,
					);
					if (!resultRaw) throw new Error("No result from Emacs");
					let result: any;
					try {
						result = JSON.parse(resultRaw);
					} catch (_err) {
						return { content: [{ type: "text", text: resultRaw }] };
					}
					if (result?.isError) throw new Error(textFromToolResult(result));
					return result;
				},
			});
		}
		const nonPichatActiveTools = pi.getActiveTools().filter((name) => !registeredTools.has(name));
		const activeTools = [...new Set([...nonPichatActiveTools, ...nextNames])];
		pi.setActiveTools(activeTools);
		// Pi 0.86 snapshots the structured prompt options before running
		// before_agent_start handlers.  Updating only the live active-tool set can
		// therefore leave this turn's provider tool list at the old snapshot.
		// Mutating the documented per-turn options keeps the prompt declaration
		// and executable tool loadout synchronized; older Pi releases still use
		// setActiveTools above.
		if (systemPromptOptions) systemPromptOptions.selectedTools = activeTools;
		ctx.ui.setStatus(STATUS_KEY, `synchronized:${tools.length}`);
	}

	pi.registerCommand("pichat-ping", { description: "Check whether the PiChat bridge extension is loaded", handler: async (_args, ctx) => { ctx.ui.notify("PiChat bridge loaded", "info"); } });
	pi.registerCommand("pichat-sync-tools", { description: "Synchronize Emacs-defined PiChat tools", handler: async (_args, ctx) => { await syncTools(ctx); } });

	pi.on("session_start", (_event, ctx) => {
		// RPC installs its stdin reader after awaiting session_start handlers.
		// Awaiting a dialog here therefore times out even when Emacs replies.
		// Let startup return before requesting bridge definitions.
		setTimeout(() => {
			void syncTools(ctx).catch((err) => {
				// A session switch may retire this startup context while the
				// dialog is pending.  Never let that terminate the RPC process.
				try {
					ctx.ui.setStatus(STATUS_KEY, `sync-error:${err instanceof Error ? err.message : String(err)}`);
				} catch { /* The replacement session owns its own synchronization. */ }
			});
		}, 0);
	});
	pi.on("before_agent_start", async (event, ctx) => {
		await syncTools(ctx, event.systemPromptOptions);
		return undefined;
	});
}
