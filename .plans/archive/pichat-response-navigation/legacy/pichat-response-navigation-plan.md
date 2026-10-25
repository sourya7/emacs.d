# PiChat rendered-response navigation plan

## Goal

Navigate between settled assistant responses from the existing rendered response view, without returning to chat or creating another view buffer. Preserve PiChat's canonical-source selection and secure Markdown rendering. This plan does **not** replace the view with `markdown-preview`.

## Behavior

- Navigate the current Pi session's **canonical transcript** in source order; never traverse visible, folded, or live-tail buffer text. Skip assistant messages with no prose (including tool-only messages). A response containing only whitespace prose remains eligible unless a separate policy is explicitly chosen.
- `next` and `previous` move to the nearest eligible assistant response. At either boundary, report that there is no further response and leave the view, point, source Markdown, and response identity unchanged.
- Keep the same read-only view buffer, window presentation, origin, and close policy. On a successful move, render the new response at the current window width and start at its beginning. `g` refreshes the newly selected response, `w` copies its exact Markdown, and `t` returns to that response in the chat. `q` retains its existing behavior.
- If the originating chat has died, its source token has changed, or the current response node no longer exists, reject navigation and preserve the readable snapshot. Do not issue RPC requests, switch Pi sessions, or navigate to a response from a different source.

## Implementation

1. In `pichat/pichat-chat-navigation.el`, add a pure adjacent-response selector taking a canonical transcript, current response node key, direction, and source token. Validate that the current key still names an assistant node; walk the ordered canonical nodes for the next/previous prose-bearing assistant; build the result using the existing exact-prose extraction path. Return a distinct boundary result (or nil with a documented contract), rather than falling back to the latest response.
2. In `pichat/pichat-chat.el`, add an origin callback for adjacent selection. Before selecting, validate the current response with `pichat-chat-navigation-response-current-p` and the current source token, as `pichat-chat--response-view-refresh` does. Pass that callback into `pichat-response-view-open`. Avoid consulting rendered chat text or triggering state synchronization.
3. In `pichat/pichat-response-view.el`, add next/previous interactive commands and a buffer-local navigation callback. Resolve the adjacent response in the origin buffer, then reuse `pichat-response-view--replace-rendering` in the **same** view buffer. Perform all validation and rendering before committing the new view so failures leave the old snapshot intact; confirm the current replacement routine meets this requirement or adjust it narrowly. Keep the existing refresh and return callbacks and origin presentation.
4. Bind native Emacs `n`/`p` in `pichat-response-view-mode-map`. In `pichat/pichat-evil.el`, bind Evil Normal `]r`/`[r` explicitly to next/previous; do not take over Evil `n`/`N` search. In `user/pichat.el`, add next/previous actions to the response view's `SPC m` menu. Update the response-view section of `pichat/README.md` and keep its description consistent with `pichat/GLOSSARY.md` (rendered response view, canonical transcript, and Pi session/source terminology).

## Verification

- Extend `pichat/test/pichat-test-response-view.el` for forward/backward order, skipped tool-only messages, boundaries, exact Markdown/copy behavior, same-buffer reuse, `g` and `t` after navigation, and unchanged snapshot on dead origin, changed source token, missing node, and render failure.
- Extend `pichat/test/pichat-test-evil.el` for `]r`/`[r` in Evil Normal state and preservation of `n`/`N`; verify native `n`/`p` bindings separately.
- Run `pichat/test/run-tests.sh` (unit suite). If the change is later broadened across the Pi RPC boundary, also run `pichat/test/run-tests.sh --full`. In PiChat manual mode, give the test command to the user to run and wait for its result; do not claim tests ran without results.
