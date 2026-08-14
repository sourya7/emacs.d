import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Deterministic standard-path pi-archive capability fixture. */
export default function (pi: ExtensionAPI) {
  pi.registerCommand("pi-archive-status-v1", {
    description: "Deterministic PiChat archive capability fixture",
    handler: async (_args, ctx) => {
      ctx.ui.notify("fixture archive status", "info");
    },
  });
}
