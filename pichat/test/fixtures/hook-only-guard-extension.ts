import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// A secrets guard with only an event hook: it registers no tools and no
// commands, so Pi's catalogue cannot show it.
export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		const path = (event.input as { path?: unknown }).path;
		if (event.toolName === "read" && typeof path === "string" && /(^|\/)\.env$/.test(path)) {
			return { block: true, reason: "hook-only-guard: secrets are protected" };
		}
	});
}
