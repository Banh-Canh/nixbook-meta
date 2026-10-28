# Talk to your desktop (Quick AI)

Quick AI puts the AI where you already are, and answers in a couple of seconds:
no agent to wait for. It all happens in **Muse's speech bubble** (the one `Mod+C`
calls up), the one place to talk to the AI: what you type or say there, a region
of the screen, a notification, a task from a Kiroshi scan. It can act on the
desktop for you.

What you ask or order there is answered by **Muse's agent** (`nixbook-meta-agent`,
the side panel's own), kept running for the bubble and started ahead, so it
answers at once, on the quick model (Settings > Desktop agents > Accuracy and
models > _Model for Muse in the bubble_, `ai.routing.quick`: the
[model provider](./ai-assistant.md)'s small one by default, Meta's
`muse-spark-1.3`). The one-shot answers about a text or an image (Explain,
Summarize, Translate, a notification's buttons, a screen region's chips) call
the provider's model directly instead, in a second or two.

**The bubble and the side panel are one conversation**: the expand button opens
it in the side panel, in the same agent session, and Muse just goes on (nothing
is replayed).

## Where to call it

| How                           | What it does                                                                                                                                                                                                                        |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Mod+C`                       | **The bubble**: type a question or an order.                                                                                                                                                                                        |
| `Mod+T` (or the bubble's mic) | **Talk.** Say what you want and stop talking: it is done. With Meta, your voice is streamed to Muse Voice Transcribe and your words show in the bubble's field as you speak; otherwise whisper.cpp transcribes it on this computer. |
| The screenshot app (`Print`)  | **Ask AI** (its toolbar button, or `A`): draw a region, pick a window or a screen; the bubble offers What's this, Explain, Summarize, Translate, **Copy text** (the text in the image), or type any question about it.              |
| `Mod+K`                       | **Kiroshi scan**: a brief of what you are in the middle of and what needs you, and the tasks it can handle for you (see below).                                                                                                     |
| `!` in the launcher           | A question or an order. A query that reads like a question also gets an **Ask AI** row.                                                                                                                                             |
| Notification buttons          | **Summarize**, and **Suggest replies** on messages: the replies are buttons in the bubble, sent in one click when the app takes inline replies, otherwise copied and the conversation opened.                                       |

## Doing things

What you say or type in the bubble is an order or a question:

1. **Plain commands are done at once, in code, with no model**: the music, the
   volume and brightness, an app, a workspace, dark mode, Do Not Disturb, night
   light, a screenshot, a timer… (the [whole list](#fast-commands)), also in the
   middle of a conversation. The bubble says **Done: …**, with **Undo**.
2. **What the desktop already knows comes with every question**: the date and
   time, the weather, the battery, your next events, the music playing. "Quel
   temps fait-il ?" or "what's next today?" is answered at once, without a tool,
   in the language you used.
3. **Your apps' own tools are its too**: the MCP servers of the side panel
   (YouTube Music, Spotify, your phone, Immich, LinkedIn…). "Play FIRESTARTER"
   or "put some music on" starts it through YouTube Music's own API in about a
   second, not by clicking in the app. Small apps' tools come with every
   request; a big one's (Immich) when you name it or the agent asks for them.
4. **Anything else goes to the model with the desktop tools** (the same ones as
   [desktop control](./desktop-agents.md): windows, workspaces, apps, layouts,
   clipboard, typing, notifications, calendar, tasks, contacts, themes,
   wallpaper, widgets, equalizer, shell actions). The bubble says which step it
   is on. When it is done, it says what changed (up to 30 steps a message).
5. **It asks only before really risky steps**: deleting your data (an event,
   photos, conversations), speaking for you to other people (an SMS, a
   message, a reply), credentials, paying, a click on a button such as
   "Delete" or "Send". **Allow** or **No** under the answer (or say yes / no).
   Closing a window, adding an event, ticking a task, clicking around or
   playing music just happen. Settings > Desktop agents > Talk to your desktop
   > _Ask me before_: _Risky steps only_ (the default), _Every action_ or
   > _Never_.
6. **What it does without asking is yours to widen**: with the
   [trust ladder](./desktop-agents.md#trust-ladder), the other steps that change
   something are done and then told (a **Did: …** line with **Undo**); after
   three yeses in a row to the same kind of step, it offers **Stop asking
   before …?**. Everything done unasked is in
   [What Muse did](./desktop-agents.md#what-muse-did), with Undo.
7. **Long orders can go on in the background**: while Muse works on a long
   order, **Do it in the background** under the bubble hands it to a
   [background task](./desktop-agents.md#background-tasks) and frees the
   bubble. "From now on, when …" or "every evening at 6, …" sets up a
   [standing order](./desktop-agents.md#standing-orders).

**It is Muse in the side panel**, with the same brain, and so is Full AI
mode:

- every desktop tool you have enabled (screenshots included: it sees them) and
  your apps' own tools;
- the side panel's system prompt: your configured prompt (without its
  formatting rules: the bubble answers in short plain text) and a summary of
  this machine (host, shell, modules, key bindings), when _Include system
  context_ is on; the how-tos, packages and Neovim keymaps it looks up with its
  `machine_help` tool when a question needs them. The prompt never changes
  between messages, so the provider caches it and it costs no time after the
  first request;
- what the desktop knows for each message, from one place (the context broker,
  `nixbook-desktop-mcp context build`): the time, weather, battery, next events
  and music, your corrections and preferences, what agents remember about you
  and your desktop memory, picked for that message, and what you just did (when
  _Recent context_ is on; the × in the bubble, or the history button in the side
  panel, leaves it out of the next message).

**It learns like the side panel too**: what a task did goes to the desktop
memory's learning pass, credited to the app it worked in (the notes that helped
count up, a new way of doing something that took work becomes a note or a
recipe), and once a conversation goes quiet, the same memory pass as the side
panel's chats saves what it showed about you. The web, your folders and the
side panel's MCP servers are the bubble's as well, as you set them for Muse.

**It checks before and after** (Settings > Desktop agents > **Accuracy and
models**, both on by default):

- **It asks back when a request could mean several things** ("Which Julien:
  the one from work or your cousin?"), before doing anything; the bubble says
  **? Muse needs a detail before doing anything**. A clear request just gets
  done, with no extra cost: only a request that may be ambiguous ("close it",
  "the other one") is read by the small model, beside the answer
  (`ai.agent.resolve`, `ai.routing.resolve`).
- **It checks its work**: after acting, and fixes it once when it isn't done.
  Most tools confirm their own effect, which is enough; otherwise one quick
  check on the small model (`ai.agent.verify`, `ai.routing.verify`). The answer
  shows first, then **… Checking it worked**, and **✓ Checked: done** or
  **⚠ Couldn't confirm it worked** with why.
- **👍 / 👎 under its answers** (`ai.agent.feedback`): 👍 tells it that was
  right (what it used counts up); 👎 asks **What did you mean?**, and the
  correction is remembered for similar requests from then on, with an offer to
  ask again with it.

It follows desktop control's own rules: `Mod+Shift+Escape` pauses it (a one-shot
answer then offers **Allow desktop control and retry**), it never types into terminals
or password managers, and every step goes to the audit log. While it acts, the
bubble lets clicks and keys through to the apps and hides from the agent's
screenshots.

**It answers like Muse in the side panel**: what it did or found, in plain
words ("Done, Firefox is on workspace 3."). **Only when part of a task failed
for good, or something needs you, it adds a report** under its answer (in the
style of a Kiroshi scan): a one-line outcome, then **DONE** (what it did,
with each result), **FAILED** (what didn't work, and why) and **NEEDS YOU** (what
only you can do or decide), and how many steps really ran (`7 steps · 6 ✓ · 1 ✗`,
counted from the tool calls, not from what the model says; a failed step it
leaves out is added; one that failed and was then done another way isn't). If
you put the bubble away while it worked, it comes back with the answer (or the bar's bubble lights up while you are busy). Expanded to
the side panel, the report is in the message.

Follow-ups typed (or said) in the bubble keep the conversation; **Copy** copies
the last answer; the stop button stops it.

**Without the bubble** (Settings > Desktop agents > Talk to your desktop >
_Show the bubble_: **Only when needed**): when you talk to it (`Mod+T`, Full AI
mode) the bubble stays out of sight; the answer is said out loud (and shown in
the mascot's balloon in Full AI mode). It comes up only for what needs your
eyes: replies to pick, an error, an OK you can't give by voice. `Mod+C` shows
it, and hides it again while you talk. With _Read the answers out_ on
_Never_, the bubble always shows (something has to answer you).

## Speed

The bubble answers as fast as the model writes, and sends it as little as it
can:

- **Plain commands use no model** (below): done in a few milliseconds, no
  tokens.
- **The answer shows and is read out as it is written**: the first sentence
  plays before the answer is over.
- **Its tools start while it is still writing**, and the bubble says
  **Doing …** at once; the checks come after the answer is shown.
- **A small, cached prompt**: the core desktop tools only (the others loaded
  when a task needs them), a summary of the machine, the latest context only;
  the agent kept running, on one open connection to the provider.

For example "open Firefox" through the agent is one model call plus at most one
quick check, where it took five.

### Fast commands

Typed or said (`Mod+T`), in English, French, German or Vietnamese, these are
done at once without the model. The bubble says **Done: …** with **Undo** when
it can be undone, and Muse hears of it with your next message.

| What               | Say                                                                         |
| ------------------ | --------------------------------------------------------------------------- |
| Music              | pause the music, play the music, next song, previous song                   |
| Volume             | volume 30, volume up, volume down, mute the sound                           |
| Brightness         | brightness up, brightness down                                              |
| Apps               | open Firefox, close Firefox, switch to Firefox                              |
| Workspaces         | workspace 2, next workspace, previous workspace, move window to workspace 3 |
| Look               | dark mode, light mode                                                       |
| Notifications      | do not disturb on, do not disturb off                                       |
| Night light        | night light on, night light off                                             |
| Screen             | take a screenshot, lock the screen                                          |
| Timers             | timer 10 min, pomodoro                                                      |
| Layouts and others | work layout (a saved layout), task: buy milk, settings                      |
| Films and episodes | play Edgerunners season 1 episode 2, watch Dune (Jellyfin)                  |

Starting a conversation, the short forms work too ("pause", "next", "louder",
"lock"). In a conversation, only commands that name what they act on go this way:
"pause it", "open the file I just downloaded" or "the other one" go to Muse,
who knows what you were talking about. An app is opened only when its name is
certain; anything unsure goes to Muse as before.

**Films and episodes (Jellyfin).** Once [Jellyfin is set up](/nixbook-shell/desktop-agents#jellyfin)
and on for Muse, a request that starts with a watching verb — play, watch,
put on, stream; lance, mets, regarde, joue; spiel, schau; xem, mở, phát, bật,
cho tôi xem — and names a title goes to `jellyfin-mcp play-query`: one search,
no model, about a second, then **Done: Playing …**, fullscreen in mpv on this
computer, from where you stopped (the player goes on to the next episodes).
"play Edgerunners season 1 episode 2", "lance Arcane saison 2", "schau Dark
Staffel 1 Folge 3", "xem Edgerunners mùa 1 tập 2", "play The Expanse S2E1" (or
`2x1`); a season without an episode starts its first one not yet watched, a
series alone its next episode.

- **Never the music**: a request naming music, a song, an album, a playlist,
  an artist, a track, the radio, a podcast, Spotify or YouTube (musique,
  chanson, Musik, Lied, nhạc, bài hát…) is left to the music commands and
  Muse.
- **A title alone** (no season or episode) plays only when it matches well;
  with a season or an episode a looser match is enough.
- **Ambiguous**: when several titles match about as well, the bubble asks
  which ("Which one: Dune (1984) or Dune (2021)?") and plays nothing.
- **Missing**: a season or an episode the series doesn't have is said
  ("Edgerunners has only 1 season."), out loud too when you spoke.
- A title it doesn't find, "play it" in a conversation, or another player
  ("… on Moonfin", "… on the TV") goes to Muse, who can play it there.

## Full AI mode

`Mod+Shift+T` (or Settings > Desktop agents > Talk to your desktop > **Full AI
mode**) hands the desktop over to the AI: you talk, it does. A little mascot
shows up and moves around the screen like a host: it shows what it hears, what it
is doing (it darts off when the agent starts a step), and what it answers, which
it jumps for joy when a task is done and wobbles when
something failed. A soft glow around the screens says the AI is in charge.

- **You keep your keyboard and mouse**: the mode never takes them, so you can
  go on working while it does what you asked. **`Mod+Shift+T` again leaves**
  (so does `Esc` in the bubble, or locking the screen).
- **The microphone stays open**, also while the agent works: give the next order
  whenever you like, it takes over. **`Mod+T` turns the microphone off or on.**
- **It talks**: what it says in its balloon (what it does, its questions, the
  outcome) is said out loud in its cute voice, the words appearing as they are
  said (never ahead of the voice), and each answer only once.
- **Its balloon tells thinking from talking**: what it thinks or is doing
  (_Thinking…_, a step, a reaction) is a dimmer thought cloud in italics with
  little circles trailing to it; what it says is the speech bubble; your words
  are quoted while it hears them. A long answer shows its latest sentences.
- **Questions stay on screen until you answer**, without calling the bubble
  up: a step that needs your OK, or a question back to you. A yes/no question
  has **Yes** / **No** to click (the only place the overlay takes clicks); or
  say "yes" or "no".
- **Interrupt it by voice**: say "stop", "wait", "hold on", "pause" (alone),
  "attends", "arrête", "warte", "halt", "dừng lại", "chờ đã"… while it works or
  talks: it stops and listens, and what follows ("wait, play jazz instead") is
  your new order. With the echo-cancelled microphone (`voice.echoCancel`) it
  also listens while it talks, so just speaking up cuts it short; its own voice
  heard back is ignored. `Mod+T` stops it too. Settings > Desktop agents >
  _Interrupt by speaking_ (`ai.voice.bargeIn`).
- The conversation is still in the speech bubble.

**It reacts to what happens** (_Full AI reacts to what happens_, on by default;
at most `ai.fullAi.reactPerHour` times an hour, 30, set in Accuracy and models):
a notification, a download, the battery running low, a screen or audio output
plugged in, the network lost, you coming back. For each, it decides in a couple
of seconds whether to **ignore** it (ads, its own doings, what you don't need),
**tell** you, **ask** you what to do ("Julien asks if you're coming tonight.
Shall I say yes?"), or **do** it. It reads what you told it this session ("if
Mathieu writes, tell him I'm in a meeting"), your desktop memory and routines,
and what you answered before for the same kind of thing. Every notification
and event goes through one queue (the shell's event reactor) and gets one
decision: while Full AI mode is on, it takes them, and Muse's
[speaking first](./desktop-agents.md#talks-to-you-on-its-own) doesn't read the
same ones again. The decision is made by the decisions model (_Model for
decisions made for you_, `ai.routing.decisions`: the big one, with low
thinking, by default).

It only acts alone on what you told it, or what you agreed to at least twice
before; otherwise it asks. It never interrupts an order you gave, and waits
until it has finished speaking.

**It keeps learning**: every reaction and your answer (yes, no, something else)
is kept, and the next time the same kind of thing happens it is handled the way
you chose. When you state a lasting preference ("always ignore Spotify", "when
my sister writes, tell me at once"), it saves it, as a routine or as a
**preference** in its memory of you, the one every AI feature reads (Settings >
Desktop agents > About you lists and deletes them). Settings > Desktop agents >
Talk to your desktop > **Forget what Full AI learned** clears its learned
reactions (`~/.local/state/nixbook-shell/full-ai-learned.json`).

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
  later, noise dimmed), each with a one-line gist and its best offer. The items
  worth acting on come first (the offers' value × urgency).
- **Open an item** (click it, or press its number) for the substance: the
  **facts** as bullets (who, what, when or the deadline, the numbers, links,
  what is asked of you), **why** it matters now and the **next** step if you do
  it yourself.
- Then up to three **offers** (`A`, `B`, `C`, best first), each with the effort
  it saves (`~2 min · 6 clicks`). The scan only offers what saves real work: a
  reply drafted with the right context, a date in a message added to your
  calendar, a request filed as a task with its due date, an error's cause and
  fix, a long thread summed up with its action items in a note, a follow-up
  reminder, information gathered across apps, several routine notifications
  cleared at once. It never offers to open, focus or scroll to what is already
  on screen, dismiss one toast, play or pause, or "keep" what is already going
  on; when nothing is worth it, the card says so.
  - A **one-step offer** is a single desktop tool call (a calendar event, a
    task, a reminder, a desktop note, a notification's button or reply,
    notifications cleared, text for the clipboard, a page looked up in Zen),
    its arguments checked before it is shown; it runs at once and shows ✓ or
    the error in the card. Desktop control's pause and guards apply.
  - One that **sends** something (a reply) or is risky shows its draft, editable,
    and waits for **Send** (`Enter`): nothing is sent without that click.
  - A **bigger offer** shows its plan and, when it writes something, the
    **draft, editable**; it goes to Muse in the bubble, which carries it out with
    the desktop tools, step by step. An offer whose draft isn't shown yet is
    chosen by the first click (to read it) and run by the second.
  - `Enter` takes the chosen offer (the best one unless you picked another).
    **Copy draft**, or **Tell me more** for a closer look at that part of the
    screen.
- **It learns what you take**: each offer you use is kept as a 👍 (desktop-mcp's
  `feedback`, surface `kiroshi`), and the next scans are told the last ten, so
  they offer more of what you actually use.
- **Handle the routine ones** does every routine item that has an offer worth
  it and needing no confirmation in one go (one-step offers run in place, the
  others go to Muse together).

The brief shows in about 4 seconds and the details follow (about 12 seconds
for everything); `Esc` closes an item, then the scan.

## Voice

`Mod+T` listens; `Mod+T` again (or the bubble's mic) stops early, `Esc` cancels.
Talk as you would to someone: a pause in the middle of a sentence is fine; what
you say ends after a longer pause (`ai.voice.pauseSeconds`, 1.8 s) and can last
up to 2 minutes (`ai.voice.maxSeconds`).

**It doesn't hear the computer**: the voice records from a microphone with the
computer's own sound taken out (a PipeWire echo canceller,
`programs.nixbook-shell.voice.echoCancel.enable`, on by default), so music or a
video playing isn't taken for what you say. After the first deploy with it,
restart PipeWire once: `systemctl --user restart pipewire pipewire-pulse wireplumber`.

**It answers out loud, in a cute voice** (_Read the answers out_: _When I talk_
by default, _Always_ or _Never_). The answer to what you said is read on this
computer by Meta's MMS voices (Massively Multilingual Speech), in English or
French, picked from the answer's language: Meta's Model API has no speech
synthesis. After acting, it says what it did (a report's outcome and what needs you, when there is one); when
a step waits for your OK, it asks "May I …?"; a plain command says what it did.
The answer is read as it is written: each sentence is said as soon as it is
complete, while the next one is made.
_Voice_ picks **Cute** (higher and bouncier, the default) or **Natural** (MMS's
own voice). The microphone doesn't take it for you, and `Mod+T` or `Esc` cuts
it short. The voices are MMS's (CC-BY-NC: for personal use).

**A conversation** (_Talk back and forth_, on by default): after `Mod+T`, once the
answer has been said, the microphone opens again by itself, so you just go on
talking. When a step waits for your OK, say "yes" / "oui" or "no" / "non". It ends
when you say "that's all", "thanks", "c'est tout", "merci"…, press `Esc`, put the
bubble away, or say nothing for 8 seconds.

Settings > Desktop agents > Talk to your desktop > _Voice transcribed by_:

- **Meta (streamed)**: the microphone is streamed to Meta's Muse Voice
  Transcribe while you speak. The words show in the bubble's field as they are
  recognised, and Meta tells when you have finished, so the order goes the
  moment you stop. Your computer only records. Your interface language and
  English are hinted to it (`ai.voice.language`, e.g. `"fr,en"`).
- **This computer**: whisper.cpp (the `small` model, or `base`), nothing leaves
  the computer; it stops after a short silence (`ai.voice.pauseSeconds`,
  measured against the room's usual noise, so typing or a fan doesn't keep it
  open). Only the parts Silero VAD finds to be speech are transcribed, so noise
  alone gives nothing instead of made-up words. It needs a reasonable GPU or
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
model of the one-shot answers (`ai.quick.model`: small, main or big). **Accuracy
and models**: asking back, checking the result, 👍 / 👎, the bubble's model
(`ai.routing.quick`), the model and thinking of the decisions made for you
(`ai.routing.decisions`, `ai.routing.decisionsEffort`) and Full AI's hourly
reactions, the models of the two checks (`ai.routing.resolve`,
`ai.routing.verify`: small) and **Speed**: minimal thinking for the checks,
reactions and one-shots (`ai.routing.effortMinimal`), only the core desktop
tools up front (`ai.agent.coreTools`), and how long the agent stays running
after the last message (`ai.agent.keepWarmMinutes`, 60; 15 while locked).
`policies.ai` (AI features off) turns all of it off.

The options are under `ai.quick`, `ai.voice`, `ai.agent` and `ai.routing` in the shell's settings, so Nix
can set them like any other (`programs.nixbook-shell.settings.ai.quick.confirm = "actions";`).

From a script: `nixbook-shell ipc call quickAi selection|screen|toggle|close`,
`quickAi ask "…"`, `quickAi approve|deny`, `quickAi status`, `voice say "…"`,
`voice hush`.
