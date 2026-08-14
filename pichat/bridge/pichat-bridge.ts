import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type, type TSchema } from "typebox";

type PiChatToolDef = { name: string; label?: string; description?: string; parameters?: unknown; mutating?: boolean };
type PiChatToolsResponse = { protocolVersion?: number; tools?: PiChatToolDef[] };

const PROTOCOL_VERSION = 1;
const CAPABILITIES = ["tools", "tool-errors", "dynamic-tool-refresh"];
const STATUS_KEY = "pichat-bridge";

const HANDSHAKE_TITLE = "__pichat_handshake__";
const TOOLS_REQUEST_TITLE = "__pichat_tools_request__";
const TOOL_CALL_TITLE = "__pichat_tool_call__";

export default function (pi: ExtensionAPI) {
	let pichatHost = false;
	const registeredTools = new Set<string>();
	const toolFingerprints = new Map<string, string>();

	async function handshake(ctx: any) {
		if (pichatHost || !ctx.hasUI) return pichatHost;
		try {
			const value = await ctx.ui.input(HANDSHAKE_TITLE, JSON.stringify({ protocolVersion: PROTOCOL_VERSION, capabilities: CAPABILITIES }), { timeout: 1000 });
			const parsed = value ? JSON.parse(value) : undefined;
			pichatHost = parsed?.protocolVersion === PROTOCOL_VERSION;
			ctx.ui.setStatus(STATUS_KEY, pichatHost ? `connected:v${PROTOCOL_VERSION}` : "incompatible-protocol");
		} catch (err) {
			pichatHost = false;
			ctx.ui.setStatus(STATUS_KEY, `error:${err instanceof Error ? err.message : String(err)}`);
		}
		return pichatHost;
	}

	function validTool(tool: unknown): tool is PiChatToolDef {
		if (!tool || typeof tool !== "object") return false;
		const candidate = tool as PiChatToolDef;
		return typeof candidate.name === "string" && /^[A-Za-z0-9_-]+$/.test(candidate.name)
			&& (candidate.label === undefined || typeof candidate.label === "string")
			&& (candidate.description === undefined || typeof candidate.description === "string")
			&& (candidate.parameters === undefined || (!!candidate.parameters && typeof candidate.parameters === "object" && !Array.isArray(candidate.parameters)))
			&& (candidate.mutating === undefined || typeof candidate.mutating === "boolean");
	}

	function schemaForTool(tool: PiChatToolDef): TSchema {
		if (tool.parameters && typeof tool.parameters === "object") {
			return Type.Unsafe(tool.parameters as TSchema);
		}
		return Type.Any();
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

	async function syncTools(ctx: any) {
		if (!(await handshake(ctx))) return;
		ctx.ui.setStatus(STATUS_KEY, "synchronizing");
		let raw: string | undefined;
		try {
			raw = await ctx.ui.editor(TOOLS_REQUEST_TITLE, JSON.stringify({ protocolVersion: 1 }));
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
		if (response.protocolVersion !== PROTOCOL_VERSION || !Array.isArray(response.tools)) {
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
				parameters: schemaForTool(tool),
				async execute(_toolCallId, params, _signal, _onUpdate, toolCtx) {
					const resultRaw = await toolCtx.ui.editor(TOOL_CALL_TITLE, JSON.stringify({ protocolVersion: 1, name: tool.name, params }));
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
		pi.setActiveTools([...new Set([...nonPichatActiveTools, ...nextNames])]);
		ctx.ui.setStatus(STATUS_KEY, `synchronized:${tools.length}`);
	}

	pi.registerCommand("pichat-ping", { description: "Check whether the PiChat bridge extension is loaded", handler: async (_args, ctx) => { ctx.ui.notify("PiChat bridge loaded", "info"); } });
	pi.registerCommand("pichat-sync-tools", { description: "Synchronize Emacs-defined PiChat tools", handler: async (_args, ctx) => { await syncTools(ctx); } });

	pi.on("session_start", async (_event, ctx) => { await handshake(ctx); await syncTools(ctx); });
	pi.on("before_agent_start", async (_event, ctx) => { await syncTools(ctx); return undefined; });
}
