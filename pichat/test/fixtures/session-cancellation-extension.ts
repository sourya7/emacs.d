import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Deterministic cancellation hooks for PiChat session-history integration. */
export default function (pi: ExtensionAPI) {
  pi.on("session_before_fork", () => ({ cancel: true }));
  pi.on("session_before_switch", (event) => ({
    cancel: event.targetSessionFile?.includes("pichat-cancel-target") ?? false,
  }));
}
