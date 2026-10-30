import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { writeFileSync } from "node:fs";

export default function (pi: ExtensionAPI) {
	function register(name: string, exposure: "direct" | "model-only" | "codemode" | "deferred" | "hidden" = "direct", description = `Fixture ${name}`) {
		pi.registerTool({ name, label: name, description,
			exposure, parameters: Type.Object({}),
			async execute() { throw new Error("Discovery must not execute tools"); },
		});
	}
	register("probe_loader");
	register("probe_child");
	for (const exposure of ["model-only", "codemode", "deferred", "hidden"] as const) {
		register(`probe_${exposure.replaceAll("-", "_")}`, exposure);
	}
	pi.on("session_start", async (_event, ctx) => {
		const scenario = process.env.PICHAT_TOOL_FIXTURE_SCENARIO;
		if (scenario === "dialog") await ctx.ui.confirm("Fixture approval", "Must not approve automatically");
		if (scenario === "hang") await new Promise((resolve) => setTimeout(resolve, 60000));
		if (scenario === "error") throw new Error("Fixture startup failure");
		// An awaited startup handler, loaded after the control helper in tests.
		await Promise.resolve();
		register("probe_session");
		register("probe_context", "direct", JSON.stringify({ cwd: ctx.cwd, marker: process.env.PICHAT_TOOL_PROBE_MARKER }));
		pi.setActiveTools(pi.getActiveTools().filter((name) => name !== "probe_child"));
	});
	pi.registerCommand("probe-report", { handler: async (_args, ctx) => {
		ctx.ui.notify(`probe-active:${JSON.stringify(pi.getActiveTools())}`, "info");
	} });
	pi.registerCommand("probe-deactivate", { handler: async () => {
		pi.setActiveTools(pi.getActiveTools().filter((name) => name !== "probe_child"));
	} });
	pi.on("session_shutdown", () => {
		if (process.env.PICHAT_TOOL_FIXTURE_SHUTDOWN) {
			writeFileSync(process.env.PICHAT_TOOL_FIXTURE_SHUTDOWN, "stopped");
		}
	});
}
