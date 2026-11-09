# Agent Desktop

Let Codex operate a separate macOS user desktop while you keep using your own. Agent Desktop connects directly to macOS Screen Sharing on the same Mac and exposes screenshots, clicks, typing, keyboard shortcuts, and scrolling through MCP.

## Get started

You need an Apple silicon Mac, Xcode or Command Line Tools with Swift 6, Homebrew, Python 3, and Codex. The backend was tested on macOS 27.2. Runtime compatibility also depends on the macOS versions supported by your Homebrew libraries.

### 1. Prepare the separate account

Create a standard macOS user named `agent` in **System Settings → Users & Groups**. Log in to that account once to complete its setup, then return to your regular account. In **System Settings → General → Sharing → Screen Sharing**, enable Screen Sharing and allow the `agent` account. Use the account password for authentication. You can leave Remote Login off for this same-Mac connection.

### 2. Build Agent Desktop

```sh
git clone https://github.com/kyle-meinhardt/agent-desktop.git
cd agent-desktop
brew install cmake openssl@4
bash scripts/create-signing-identity.sh
bash scripts/build.sh
./dist/agent-desktop doctor
```

Create the local signing identity before configuring your session so future builds can retain Keychain access. macOS may prompt for permission to use the `Agent Desktop Local` signing key during the first build. Confirm the identity and tool in the prompt before approving it. The doctor command should report `sessionLibraryAvailable: true`.

### 3. Verify the desktop and enable input

```sh
./dist/agent-desktop configure agent
./dist/agent-desktop action agent screenshot --output /tmp/agent-desktop.png
open /tmp/agent-desktop.png
```

Enter the **agent account password** at the hidden prompt. The app stores it in Keychain. The default connection is `127.0.0.1:5900`. If Keychain asks whether Agent Desktop may access the saved credential, allow it for future connections. If the first screenshot times out while the session starts, retry the screenshot.

Inspect the image and confirm it belongs to the separate account before enabling input. If you see a login prompt, complete account setup and check again. The server must grant a virtual user session, and the screenshot confirms which desktop you reached.

```sh
./dist/agent-desktop approve agent
```

### 4. Add the server and skill to Codex

From the repository directory:

```sh
codex mcp add agent-desktop -- "$PWD/dist/agent-desktop" mcp agent
skill_root="${CODEX_HOME:-$HOME/.codex}/skills"
mkdir -p "$skill_root"
cp -R skills/agent-desktop "$skill_root/"
```

Start a new local Codex session and ask it to use **$agent-desktop** to take a screenshot and verify the separate account. Then give it a task to perform there. Keep this checkout in place because Codex launches the executable by its absolute path.

To disable input while retaining screenshots:

```sh
./dist/agent-desktop revoke agent
```

## Scope

Agent Desktop uses a separate account on the same OS. Both accounts share system resources. The connection only accepts loopback addresses and requires a virtual user session grant. Screen Sharing stays enabled while the tool is in use. Input supports vertical scrolling and Basic Multilingual Plane text, including accented characters. Use a scrollbar drag for horizontal movement.

## Development and attribution

```sh
bash scripts/build-session-library.sh
swift test
python3 scripts/test-session-rfb.py
```

The source retains attribution for the terminal-mac code used to develop the session backend. See the [license](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
