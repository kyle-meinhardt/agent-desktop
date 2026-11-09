---
name: agent-desktop
description: Use the agent-desktop MCP server to operate or visually verify apps, browsers, and simulators in a separate macOS user session.
---

# Agent Desktop

Use the registered `agent-desktop` MCP tools for GUI work in the configured separate macOS account.

Before the first input, call `status` and confirm that the authenticated user matches the intended account, the session type is `virtual`, and input is approved. Call `screenshot` and confirm it shows the expected separate desktop. The status response establishes the server grant, while the screenshot lets you verify the actual target.

Use the screenshot's pixel coordinates for input. Take a fresh screenshot after an action that changes the layout or focus. Use screenshots to verify the requested result.

If the session or account is uncertain, leave input paused and tell the user what needs attention. Leave sign-in and permission prompts to the user. If the server or target desktop is unavailable, report the blocker and continue work that does not require GUI access. Keep screen capture and GUI input in the separate session.
