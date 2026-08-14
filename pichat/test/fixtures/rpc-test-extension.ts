import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Deterministic extension fixture for PiChat RPC integration tests.
 *
 * This fixture intentionally contains no behavior unless invoked through slash
 * commands.  Tests can load it alongside the fake provider to exercise real Pi
 * extension UI request/response paths without network, user config, or model
 * APIs.
 */
export default function (pi: ExtensionAPI) {
  pi.registerCommand("pichat-test-input", {
    description: "Emit a deterministic input UI request",
    handler: async (_args, ctx) => {
      const value = await ctx.ui.input("PiChat test input", "test value");
      ctx.ui.notify(`input:${value ?? "<cancelled>"}`, "info");
    },
  });

  pi.registerCommand("pichat-test-confirm", {
    description: "Emit a deterministic confirm UI request",
    handler: async (_args, ctx) => {
      const confirmed = await ctx.ui.confirm("PiChat test confirm", "confirm body");
      ctx.ui.notify(`confirm:${confirmed ? "yes" : "no"}`, "info");
    },
  });

  pi.registerCommand("pichat-test-editor", {
    description: "Emit a deterministic editor UI request",
    handler: async (_args, ctx) => {
      const value = await ctx.ui.editor("PiChat test editor", "initial text");
      ctx.ui.notify(`editor:${value ?? "<cancelled>"}`, "info");
    },
  });

  pi.registerCommand("pichat-test-select", {
    description: "Emit a deterministic select UI request",
    handler: async (_args, ctx) => {
      const value = await ctx.ui.select("PiChat test select", ["alpha", "beta"]);
      ctx.ui.notify(`select:${value ?? "<cancelled>"}`, "info");
    },
  });

  pi.registerCommand("pichat-test-status", {
    description: "Emit deterministic fire-and-forget status updates",
    handler: async (_args, ctx) => {
      ctx.ui.setStatus("pichat-test", "working");
      ctx.ui.notify("status:set", "info");
    },
  });

  pi.registerCommand("pichat-test-fire-ui", {
    description: "Emit deterministic fire-and-forget UI updates",
    handler: async (_args, ctx) => {
      ctx.ui.setWidget("pichat-test", ["widget line one", "widget line two"], { placement: "aboveEditor" });
      ctx.ui.setTitle("PiChat extension title");
      ctx.ui.setEditorText("extension draft");
      ctx.ui.notify("fire-ui:done", "info");
    },
  });

  pi.registerCommand("pichat-test-block", {
    description: "Block until the current run is aborted when a signal is active",
    handler: async (_args, ctx) => {
      const signal = ctx.signal;
      if (!signal) {
        ctx.ui.notify("block:no-signal", "warning");
        return;
      }
      await new Promise<void>((resolve) => {
        if (signal.aborted) {
          resolve();
          return;
        }
        signal.addEventListener("abort", () => resolve(), { once: true });
      });
      ctx.ui.notify("block:aborted", "info");
    },
  });

  pi.registerCommand("pichat-test-shutdown", {
    description: "Request Pi shutdown through the extension context",
    handler: async (_args, ctx) => {
      ctx.shutdown();
    },
  });
}
