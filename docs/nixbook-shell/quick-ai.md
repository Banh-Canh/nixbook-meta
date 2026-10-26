# Talk to your desktop (Quick AI)

Quick AI puts the AI where you already are, and answers in a couple of seconds:
no agent to start, no panel to open. One card at the top of the screen answers
about a region of the screen, a notification, or simply what you say or type, and it can act on the desktop for you.

It calls the [model provider](./ai-assistant.md)'s small model directly (Meta:
`muse-spark-1.3`, about 2 to 5 seconds). With Anthropic as the provider, Claude
Code answers instead, using Haiku and your own login, a little slower.

## Where to call it

| How                          | What it does                                                                                                                                                                                                       |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Mod+T`                      | **Talk.** Say what you want and stop talking: it is done. With Meta, your voice is streamed to Muse Voice Transcribe and your words show as you speak; otherwise whisper.cpp transcribes it on this computer.      |
| The screenshot app (`Print`) | **Ask AI** (its toolbar button, or `A`): draw a region, pick a window or a screen, and the card offers What's this, Explain, Summarize, Translate, **Copy text** (the text in the image) or any question about it. |
| `Mod+K`                      | **Kiroshi scan**: a brief of what you are in the middle of and what needs you, and the tasks it can handle for you (see below).                                                                                    |
| `!` in the launcher          | A question or an order. A query that reads like a question also gets an **Ask AI** row.                                                                                                                            |
| Notification buttons         | **Summarize**, and **Suggest replies** on messages. A reply is sent in one click when the app takes inline replies, otherwise it is copied and the conversation opened.                                            |
| Settings > Desktop agents    | **Talk to your desktop > Try it** opens the empty card.                                                                                                                                                            |

## Doing things

What you say or type in the empty card (or by voice) is an order or a question:

1. **Plain commands are done at once, in code, with no model**: the music (play,
   pause, next), the volume and brightness, dark mode, Do Not Disturb, opening an
   app, a saved window layout, a timer. The card says what it did and goes away.
2. **Anything else goes to the model with the desktop tools** (the same ones as
   [desktop control](./desktop-agents.md): windows, workspaces, apps, layouts,
   clipboard, typing, notifications, calendar, tasks, contacts, themes,
   wallpaper, widgets, equalizer, shell actions). Each step shows in the card as
   it runs. When it is done, one sentence says what changed.
3. **It asks before anything destructive** (closing a window, deleting an
   event): **Allow** (or `Enter`) or **No**. Settings > Desktop agents > Talk to
   your desktop > _Ask me before_ also offers _Every action_ and _Never_.

It follows desktop control's own rules: `Mod+Shift+Escape` pauses it (the card
then offers **Allow and retry**), it never types into terminals or password
managers, and every step goes to the audit log.

## In the card

- `Ctrl+1` … `Ctrl+6` switch the mode, `Alt+1` … `Alt+3` pick a suggested reply.
- `Ctrl+Enter` replaces the selection, `Ctrl+C` copies the answer.
- The field at the bottom asks a follow-up, which keeps the conversation.
- **Continue in chat** takes the conversation to the side panel's chat, where
  Claude Code works with the desktop tools.
- `Esc`, or a click outside, closes the card.

## Set up the desktop by talking

Settings > Desktop agents > Talk to your desktop > **Set up my desktop by
talking** opens a chat that turns how you work ("I'm a developer, I hate
notifications at night, I like a minimal bar") into Nix:

1. It asks up to four short questions, one at a time. **Write it now** skips the
   rest.
2. It writes the shell's settings as Nix, and Home Manager or NixOS options only
   when you ask for them.
3. **Nix checks it**: the snippet must parse, and the shell settings are
   evaluated against their real typed options. A misspelt key or a wrong value
   fails with Nix's own message, which goes back to the model to fix, up to
   three rounds. The configuration shows _Checked by Nix_ once it passes.
4. You get **Copy**, **Build it for me** (files it for the desktop agent's
   [fixer](./self-improve.md), which opens a pull request, when its features are
   on) and **Apply now** (the settings change live in the shell, not in your Nix
   files; settings already set in Nix are left alone).

Home Manager and NixOS blocks are only parse-checked.

## Kiroshi scan

`Mod+K` turns the screen into a brief, so you don't have to read everything to
know what needs you. The AI looks at the screen together with what you are
doing (the focused window, your recent windows and activity, the latest
notifications, your next events) and shows:

- **Focus** and **Doing** at the top: the one thing that matters now, and what
  you are in the middle of.
- **What matters, framed on the screen**, coloured by urgency (now, soon,
  later, noise dimmed), each with a one-line gist.
- **Open an item** (click it, or press its number) for the substance: key
  facts, who asks what, what an error means. Then **what the AI can do**:
  a short plan and, when the task writes something (a reply, a message, a
  commit message), the **draft, editable**. **Do it** (`Enter`) hands the task
  to Quick AI, which carries it out with the desktop tools, step by step.
  **Copy draft**, or **Tell me more** for a closer look at that part of the
  screen. Items only you can decide say so.
- **Handle the routine ones** does every item the AI can deal with alone
  (noise to dismiss, acknowledgements, todos) in one go.

The brief shows in about 4 seconds and the details follow (about 12 seconds
for everything); `Esc` closes an item, then the scan.

## Voice

`Mod+T` listens; `Mod+T` again (or the card's mic) stops early, `Esc` cancels.
Settings > Desktop agents > Talk to your desktop > _Voice transcribed by_:

- **Meta (streamed)**: the microphone is streamed to Meta's Muse Voice
  Transcribe while you speak. The words show in the card as they are
  recognised, and Meta tells when you have finished, so the order goes the
  moment you stop. Your computer only records. Your interface language and
  English are hinted to it (`ai.voice.language`, e.g. `"fr,en"`).
- **This computer**: whisper.cpp (the `small` model, or `base`), nothing leaves
  the computer; it stops after a short silence. It needs a reasonable GPU or
  CPU (about a second for a short sentence on a Radeon 680M).
- **Auto** (the default): Meta when it is the model provider, otherwise this
  computer.

## Privacy

Text goes through the [privacy mask](./desktop-agents.md) on the way out (names,
emails and the like become placeholders such as `⟦Person 1⟧`) and the answer is
unmasked on this computer. Every request is listed under _What it sent_. With the local engine the
voice never leaves the computer, only its text does; with Meta it is streamed
to Meta. Screen regions and Kiroshi
scans are images: they go to the provider as they are.

## Settings

Settings > Desktop agents > **Talk to your desktop**: Quick AI on or off, voice,
the launcher and notification buttons, typed-out answers, when to ask, and the
model (small, main or big). `policies.ai` (AI features off) turns all of it off.

The options are under `ai.quick` and `ai.voice` in the shell's settings, so Nix
can set them like any other (`programs.nixbook-shell.settings.ai.quick.confirm = "actions";`).

From a script: `nixbook-shell ipc call quickAi selection|screen|toggle|close`,
`quickAi ask "…"`, `quickAi approve|deny`, `quickAi status`.
