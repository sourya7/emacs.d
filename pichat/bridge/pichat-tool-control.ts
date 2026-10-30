import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";

// An unsupported/inaccessible procfs disables SSH restart, not ordinary RPC.
// This is the actual RPC writer, which need not be TRAMP's remote shell PID.
function processIdentity() {
	if (process.platform !== "linux") return null;
	try {
		const stat = readFileSync("/proc/self/stat", "utf8");
		const fields = stat.slice(stat.lastIndexOf(") ") + 2).trim().split(/\s+/);
		const start = fields[19];
		const boot = readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
		if (!/^\d+$/.test(start ?? "") || !/^[0-9a-f-]{36}$/.test(boot)) return null;
		return { kind: "linux-procfs-v1", pid: process.pid, start, boot };
	} catch {
		return null;
	}
}

// Internal RPC transport, not a model tool or a conversation message.
const COMMAND = "pichat-tool-control-v1";
const TITLE = "__pichat_tool_control_v1__";
const LIMIT = 1024 * 1024;
const NAME = /^[A-Za-z0-9_-]+$/;

export default function (pi: ExtensionAPI) {
	pi.registerCommand(COMMAND, {
		description: "PiChat internal tool catalogue and startup control (protocol 1)",
		handler: async (args, ctx) => {
			if (ctx.mode !== "rpc") return;
			let requestId: string | undefined;
			let shutdownAfterAck = false;
			let result: object;
			try {
				if (Buffer.byteLength(args, "utf8") > LIMIT) throw new Error("Request too large");
				const request = JSON.parse(args);
				if (request.protocolVersion !== 1 || typeof request.requestId !== "string"
					|| request.requestId.length > 128 || !request.requestId.length) {
					throw new Error("Invalid tool-control request");
				}
				requestId = request.requestId;
				if (!ctx.isIdle()) throw new Error("Tool control requires an idle runtime");
				const all = pi.getAllTools();
				if (all.length > 4096) throw new Error("Too many registered tools");
				if (request.operation === "enable") {
					if (!Array.isArray(request.names) || request.names.length > 4096
						|| !request.names.every((name: unknown) => typeof name === "string"
							&& name.length <= 256 && NAME.test(name))
						|| new Set(request.names).size !== request.names.length) {
						throw new Error("Invalid tool selection");
					}
					// Validate the entire selection before mutating anything. Never expand
					// dependencies, execute loaders, or bypass the CLI allowlist.
					for (const name of request.names) {
						const tool = all.find((candidate) => candidate.name === name);
						if (!tool || tool.exposure === "hidden") throw new Error(`Cannot enable tool: ${name}`);
					}
					const previous = pi.getActiveTools();
					try {
						pi.setActiveTools([...new Set([...previous, ...request.names])]);
						const active = new Set(pi.getActiveTools());
						if (!request.names.every((name: string) => active.has(name))) {
							throw new Error("Pi rejected tool activation");
						}
					} catch (error) {
						pi.setActiveTools(previous);
						throw error;
					}
				} else if (request.operation !== "catalogue") {
					throw new Error("Unknown tool-control operation");
				}
				// A no-session SSH discovery probe cannot rely on stdin EOF
				// traversing TRAMP.  Only the explicit probe request opts in.
				shutdownAfterAck = request.operation === "catalogue" && request.shutdownAfterAck === true;
				const activeTools = pi.getActiveTools();
				result = {
					ok: true,
					processIdentity: processIdentity(),
					tools: pi.getAllTools().map((tool) => ({
						name: tool.name,
						description: tool.description.slice(0, 4096),
						exposure: tool.exposure ?? "direct",
					})),
					activeTools,
				};
			} catch (error) {
				result = { ok: false, error: (error instanceof Error ? error.message : String(error)).slice(0, 1024) };
			}
			let payload = JSON.stringify({ protocolVersion: 1, requestId, ...result });
			if (Buffer.byteLength(payload, "utf8") > LIMIT) {
				payload = JSON.stringify({ protocolVersion: 1, requestId, ok: false, error: "Catalogue too large" });
			}
			// Ack closes the internal dialog. Nothing is appended to the Pi session.
			const ack = await ctx.ui.input(TITLE, payload, { timeout: 5000 });
			if (shutdownAfterAck && ack === "ack") ctx.shutdown();
		},
	});
}
