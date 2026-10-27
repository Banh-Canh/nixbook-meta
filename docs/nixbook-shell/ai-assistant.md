# AI chat & config assistant

The **left sidebar** (Mod+Space) holds a chat with two models:

| Model                          | What it is                                                                                                                                                              |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Config assistant** (default) | Offline, no AI: answers instantly from this machine's configuration                                                                                                     |
| **Muse** (`/model muse`)       | nixbook's own agent (`nixbook-meta-agent`) on Meta's Model API, with the desktop tools attached; or on [another model provider](#model-provider-meta-or-another-server) |

## Config assistant

The config assistant answers from facts generated from your evaluated configuration, in **English, French, German and Vietnamese** (detected from the question), in under 100 ms:

- **key bindings**: "how do I open the launcher?", "what does Mod+R do?", "all vim shortcuts" (NixVim's real keymaps, overrides included);
- **your system**: NixOS release, kernel, host, time zone, locale, keyboard layout, bootloader, shell, editor;
- **"is X enabled?"** for every module option with an `enable` switch, and "is X installed?" for packages;
- **shell settings**: "what does `bar.bottom` do?", and the settings pinned in Nix;
- **how-tos**: updating, rolling back, freeing disk space, syncing your calendar, stopping the desktop agents, window layouts, Muse in the panel…

`/help` (or "help", "aide", "hilfe", "giúp") lists the kinds of questions it answers. When nothing matches exactly, it shows the closest facts; off-topic questions get "I don't know" and tips. Answers are selectable and copyable.

### Teaching it about your machine

`programs.nixbook-shell.assistant` controls what it — and Muse — knows:

| Option       | What                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------- |
| `context`    | Free text about the machine (nixbook fills in host, enabled modules, profile paths, how to deploy)      |
| `coreFacts`  | Key statements always included                                                                          |
| `niriConfig` | Niri's bindings, turned into "Press Mod+D to open the app launcher" facts                               |
| `nixvim`     | NixVim keymaps and leader (default: the evaluated ones)                                                 |
| `os`         | System facts                                                                                            |
| `howTo`      | Named how-to answers; set one to your own way (a deploy tool, an update script) or `null` to drop it    |
| `mcpServers` | MCP servers given to Muse (default: [MCP-NixOS](https://mcp-nixos.io) for real package and option data) |

On NixOS, add the shell's `nixosModules.default` so "is X enabled?" also covers system options (Home Manager modules only see the NixOS configuration, not its options). nixbook does this for you.

## Muse in the side panel

**Muse** is Meta's model family; in the chat it is nixbook's own agent, `nixbook-meta-agent`, talking to [Meta's Model API](https://dev.meta.ai/docs/coding-agents) with the desktop tools attached. It is offered once the agent is installed (it comes with the shell) and needs a Meta API key. Set it up in **Settings → Desktop agents → Muse in the side panel**:

- whether it is ready (a key saved) and a button to use it in the panel (`/model muse` does the same);
- the model — **Muse Spark** by default (`main`), **Muse Wonder** (`big`) or the small one — and thinking effort (low by default: desktop tasks are many short steps);
- whether it may search and read the web;
- the folders it may read.

Replies stream in, each tool call shows with its result in a collapsible block, and the send button (or `/stop`) stops the answer: the agent is stopped, and your next message resumes its session. The agent keeps running between messages, so replies start immediately: it starts as soon as you open the panel on Muse, closes after an hour unused (15 minutes while the screen is locked; `ai.agent.keepWarmMinutes`) and starts again ahead when you unlock or the screens come back on.

This fork uses Meta only: Claude Code, the claude.ai connectors, the Claude usage bar widget and signing in with a Claude subscription are gone on purpose.

### Model provider: Meta, or another server

**Settings → Desktop agents → Muse in the side panel → Model provider** (`ai.provider`):

| Provider           | What answers                                                                                                                                                       |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Meta** (default) | [Meta's Model API](https://dev.meta.ai/docs/coding-agents) (`https://api.meta.ai`): `muse-spark-1.3` as the main and small model, `muse-wonder-1.0` as the big one |
| **Other** (custom) | any server with a compatible Messages API (`https://`, or `http://` on this computer), with the models you name                                                    |

Create a key in the Model API dashboard, paste it in the **API key** field and click **Save**, then **Test** (one short request). The key is kept in your keyring, per provider and server: a key saved for one server is never sent to another. The main, small and big model fields override the preset's.

Everything an agent does for you switches together: the side panel (the model shows as "Muse", or the custom provider's model), [Quick AI and the speech bubble](./quick-ai), [speaking on its own](./desktop-agents), the memory passes, routines, the equalizer agent and [the fixes it makes](./self-improve). The tools and limits stay the same (the desktop tools, the sandbox, the folders you allow) and the [privacy mask](./desktop-agents) still applies. Switching provider starts the panel's agent again, each chat in a new session (the conversation so far goes with your next message). Without a key nothing answers: the chat says what is missing.

From a terminal: `nixbook-model-provider status`, `nixbook-model-provider test`, and `nixbook-meta-agent -p` (the prompt on stdin) to run the agent on the chosen provider yourself.

### What Muse can and can't do

- It drives the desktop through the [desktop control tools](./desktop-agents) — with their guardrails, the pause button and the memory.
- It remembers what you tell it about your life across conversations — the [personal memory](./desktop-agents#personal-memory): one short entry per subject, and only the entries about what you're talking about come with your message.
- It gets the MCP servers of `assistant.mcpServers` and only the built-in tools in `ai.agent.allowedTools` (web search and fetch). **Running commands is refused.**
- **It reads none of your files** unless you allow it: _Folders AI agents may read_ (`ai.allowedFolders`, none by default) become read-only working directories, and a file attached to a message is readable on its own.
- **It writes files only where you let it**: in _Folders AI agents may write_ (`ai.writableFolders`, none by default) it can create and edit files; anywhere else is refused.
- It runs in an empty directory of its own (`~/.local/share/nixbook-shell/assistant`), and its file tools refuse every path outside the folders above.
- **Command line** (`ai.agent.commandLine`, off by default): Muse may run commands on this computer as you (its Bash tool). It never types into terminal windows: a terminal has your full access. It looks around freely but says exactly what it will run, and waits for your yes in the chat, before anything that changes the system or your files: installing, removing or editing files, `sudo`, `systemctl`, git commits or pushes, NixOS switches, sending data off the machine. **Only in the allowed folders** (`ai.agent.commandLineFolders`, on by default) keeps it to the folders below, enforced by the agent's sandbox (bubblewrap, in a PID namespace of its own): in your home only the allowed folders can be read and the writable ones written; the rest of your home is hidden (your SSH keys, logins…), and so are your runtime directory and removable drives; writes elsewhere fail (but in a `/tmp` of its own, gone afterwards), and what runs on its own later (`.git`, `.envrc` at the top of a writable folder) can't be written; the system's programs and the network work; a command is never retried outside the sandbox (without bubblewrap it isn't run at all). Its Write and Edit tools work in the writable folders only. What its commands start stays inside too: systemd, D-Bus and the compositor are out of reach, so nothing can be launched outside it that way. Apps it opens with the desktop tools (not its commands) run on your desktop as before; [the agents' own desktop](./agent-desktop) confines those to the allowed folders too. Turned off, its commands have your full access.
- **Speak as this computer** (`ai.agent.asComputer`, on by default): Muse answers as the machine itself — "my CPU is an AMD Ryzen 7 6800U", "my battery is at 80%, though its health is down to 46%" — reading its hardware, OS and kernel live through the desktop tools' `system_info` rather than guessing.

With a model selected, the configuration facts become reference for the model: it answers with its own knowledge too, and says when it isn't sure. `ai.includeSystemContext` (on by default; Settings → Services → AI) controls whether the machine context is sent. What it sends is a **short summary** of this machine (host, shell, enabled modules, the key bindings, about 6000 characters, `~/.config/nixbook-shell/system-context-summary.md`); for how-tos, packages and Neovim keymaps Muse searches the whole reference with its `machine_help` tool, only when a question needs them.

### What comes with each message

Each message to Muse starts with what the desktop knows for it, picked for that message from one place (the context broker, `nixbook-desktop-mcp context build`), the same for the side panel, [the speech bubble](./quick-ai), Full AI mode and Muse [speaking first](./desktop-agents#talks-to-you-on-its-own): the time, weather, battery, next events and music; your corrections and preferences that bear on it; what agents remember [about you](./desktop-agents#personal-memory) and [about your desktop](./desktop-agents#desktop-memory); and, with _Know what I was just doing_ on, what you were just doing. The **history** icon beside the message box leaves that last part out of the next message.

### One Muse, in the panel and the bubble

The speech bubble (Mod+C) runs the same agent: expanding it opens the conversation here, in the same session, and Muse goes on without anything being replayed. Both use one memory.

### Asking before it acts

With the [trust ladder](./desktop-agents#trust-ladder) on (`ai.autonomy.trust`, the default), each kind of step Muse takes is asked about first, done and told after, or done silently, as you set it. A step it asks about shows a bar above the message box, **Muse asks before: …** with **Allow** and **No**. Under its answers come the **Did: …** lines (with **Undo**), the **Stop asking before …?** suggestions and the cards of [standing orders](./desktop-agents#standing-orders) it set up (**Turn on**, **Edit**, **No**), as in the bubble.

### Accuracy

**Settings → Desktop agents → Accuracy and models** (all on by default):

- **Ask back when a request is ambiguous** (`ai.agent.resolve`): before acting on a request that could mean several things, Muse asks which one you meant, and does nothing until you answer. It costs nothing on a clear request: only one that may be ambiguous ("close it" with nothing to point at, "the other one", a verb alone) is read by a second model (_Model that tells whether a request is ambiguous_, `ai.routing.resolve`, the small one), beside the answer, which keeps streaming meanwhile; only its tools wait for the verdict.
- **Check the result after acting** (`ai.agent.verify`): after a message in which it changed something, the result is checked, and fixed once if the goal isn't met. Most desktop tools confirm their own effect (the window opened, the music paused), and then nothing more is asked; otherwise one quick check by _Model that checks the result_ (`ai.routing.verify`, small). The answer shows at once; **Checked: done** or **Couldn't confirm it worked** and why appears under it a moment later.
- **👍 / 👎 under the answers** (`ai.agent.feedback`): 👍 tells Muse that was right (the memory notes it used get stronger); 👎 opens **What did you mean?**: Enter saves your correction, which comes back with similar requests from then on, and offers to ask again with it. Escape saves the 👎 alone. Nothing goes to a model when you click.

The same page picks the models: the bubble's (`ai.routing.quick`, small by default), and the one for what is decided on your behalf — which notifications deserve a word, Full AI's reactions, pairing, a routine's judgment (`ai.routing.decisions`, the big one by default, with low thinking: `ai.routing.decisionsEffort`) — and the two check models above.

### Speed

Muse is made to answer as fast as the model writes and to send as little as it can:

- **Plain commands need no model at all**, in the bubble, also in the middle of a conversation: see [the fast commands](./quick-ai#fast-commands).
- **The answer shows, and is read out, as it is written**: the first sentence is spoken before the answer is over; the checks come after it.
- **Its tools start while it is still writing**, each one as soon as the model has finished asking for it; the bubble says **Doing …** the moment one starts.
- **A small prompt, cached**: only the ~25 core desktop tools are sent up front, the others loaded by group the first time a task needs them; the machine reference is a summary; earlier messages' context is left out of what is sent again; tool results are cut to what the model needs. The provider caches the rest, so a message after the first costs little.
- **One connection kept open** to the provider, and the agent kept running between messages.

**Settings → Desktop agents → Accuracy and models → Speed**:

| Setting                                                                                                                                 | Default |
| --------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| _Minimal thinking for the checks, the reactions and the one-shot answers_ (`ai.routing.effortMinimal`)                                  | on      |
| _Only the core desktop tools up front (the others loaded when needed)_ (`ai.agent.coreTools`)                                           | on      |
| _Keep Muse warm (minutes)_ (`ai.agent.keepWarmMinutes`): the agent kept running after the last message while unlocked (15 while locked) | 60      |

## Tabs

The chat has **tabs**, each its own conversation answering on its own, so Muse can work on several things at once: **+** above the chat (or **Ctrl+T**) opens one, **Ctrl+Tab** / **Ctrl+Shift+Tab** go through them, and **×**, a middle-click or **Ctrl+W** closes one (its conversation stays in the history). A tab shows a spinner while it works and a dot when it answered while you were elsewhere; when the panel is closed, the notification's **Open** opens that tab. Up to 8 tabs.

Each tab runs its own agent. When agents work on [their own desktop](./agent-desktop), each tab also gets **its own desktop**, so they don't fight over one pointer and keyboard: the first tab uses "Assistant's desktop", the others "Assistant's desktop 2", "3"… (the number shows on the tab). Closing a tab closes its desktop.

## Conversations

Every conversation is saved as you chat, after each answer. The **history** button at the top of the chat (or **Ctrl+H**, or `/history`) lists them — pinned first, then by day — to go back to one:

- **click** one to open it (in its tab, if a tab has it open; the **tab** button or a middle-click opens it in a new one); with Muse, it resumes the same agent session when the agent still has it (it keeps sessions a week), otherwise the conversation so far goes with your next message;
- **search** by title; Up/Down and Enter open one from the keyboard, Esc goes back;
- **rename** one (its pencil, or right-click), **pin** it to keep it for good, or **delete** it; **Delete all** deletes every conversation but the pinned ones (click twice);
- **New conversation** (the button beside the token count, or `/clear`) starts a fresh one; the current one stays in the history.

Conversations are deleted **30 days after their last message**, unless pinned. Change that in **Settings → Services → AI** (_Keep conversations for_, `ai.history.keepDays`; `0` keeps them until you delete them), which also deletes them all but the pinned ones. They're stored in `~/.local/state/quickshell/user/ai/history/`.

## Muse tab

The tab after the chat (while background tasks or the journal are on, Settings → Desktop agents → Autonomy) shows what Muse does on its own: its [background tasks](./desktop-agents#background-tasks) (status and steps, **Allow** / **No** for a step waiting for your OK, a field to answer its question, **Open**, **Stop**, **Resume**) and [What Muse did](./desktop-agents#what-muse-did), by day, with **Undo**. The bar's tasks button and a task's notification (**Open**) open it.

## Translator

The sidebar's **Translator** tab translates text between languages.

The agent keeps a transcript of every session (`~/.local/state/nixbook-shell/agent-sessions/<id>.json`, readable by you only). A deleted chat's goes with it, and the agent removes those unused for a week.
