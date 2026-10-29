"""nixbook-nix-onboard: setting up the desktop by talking (services/
NixOnboarding.qml). A short conversation (a few questions, one at a time)
about who the user is and how they want their desktop, then a Nix
configuration the model writes and this script checks with Nix itself,
handing the errors back to the model until it passes (3 rounds at most):

  - every block is parsed (`nix-instantiate --parse`);
  - the shell's settings are evaluated against their real typed options
    (lib.evalModules with nixbook-shell's settingsModule, generated from the
    shell's built-in defaults), so a misspelt key or a wrong type fails with
    Nix's own message, as it would in the user's configuration.

Run through `nixbook-model-provider run nixbook-nix-onboard turn REQ.json`
(the provider's Messages API with its key; Meta: muse-spark). The request:
{messages: [{role: user|assistant, text}], lang, host, user}. Events, one
JSON object per line on stdout:
  {"type": "say", "text"}                     the assistant's message
  {"type": "checking", "round"}               a check starting
  {"type": "check", "round", "ok", "stage", "errors", "ms"}
  {"type": "fix", "round", "text"}            what the model changed after a failed check
  {"type": "config", "nix", "where", "explanation", "checked", "shell", "settings"}
  {"type": "error", "error"}
  {"type": "done", "ms"}

Paths (set by the package's wrapper; from the source tree otherwise):
NIXBOOK_SETTINGS_LIB (a directory with lib.nix, builtin-defaults.json and
src/modules/common/themes.json) and NIXBOOK_NIXPKGS_LIB (nixpkgs' lib/).
"""

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

# The shared client (nixbook_ai.py), next to this script in the source tree
# and in the package.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import nixbook_ai  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SETTINGS_LIB = os.environ.get("NIXBOOK_SETTINGS_LIB") or os.path.dirname(HERE)
NIXPKGS_LIB = os.environ.get("NIXBOOK_NIXPKGS_LIB") or ""
LANGS = {"en": "English", "fr": "French", "de": "German", "vi": "Vietnamese", "es": "Spanish",
         "it": "Italian", "ja": "Japanese", "zh": "Chinese", "pt": "Portuguese"}
MAX_FIXES = 3
MAX_QUESTIONS = 4
BLOCKS = ("shell", "home-manager", "nixos")

SYSTEM = """You set up the user's desktop by talking with them: nixbook, a NixOS desktop (niri compositor, its own \
shell "nixbook-shell", Home Manager). Warm, quick, concrete. Answer in the language the user writes in ({lang} when unsure).

How the conversation goes:
- Ask one short question at a time (at most {max_q} in all) about who they are and how they want their desktop: \
what they do on it, what bothers them (notifications, brightness at night, clutter), the look they like. Offer \
two or three examples in each question so answering is quick.
- As soon as you know enough (or they say "go", or after {max_q} questions), write the configuration.

How you write the configuration (only then): your message, then the blocks, each one plain Nix, no fence:
<shell>
{{ ... }}
</shell>
  The value of the shell's settings (in nixbook: customHomeManagerModules.nixbookShellConfig.settings; elsewhere: \
programs.nixbook-shell.settings): ONE attrset using ONLY the keys of the list below, with the type of their \
default (true/false, numbers, "strings", [ lists ]). Nested attrsets or dotted keys (a.b.c = 1;). Only the keys \
you change.
<home-manager>
{{ ... }}
</home-manager>
  Optional, and left out unless the user asked for something the shell settings can't do: a Home Manager \
module as a plain attrset (no function header, no pkgs), standard Home Manager options you are sure of.
<nixos>
{{ ... }}
</nixos>
  Optional, the same way: NixOS, plain attrset, standard options only, only when asked.
Each block must be a single Nix attrset that parses. Before the blocks, say in two or three short lines what it \
does for them (no Nix in that text). Don't invent keys: a key not in the list fails the check.

The shell's settings (key = built-in default):
{catalog}"""

QUESTION_SYSTEM = """You set up the user's desktop by talking with them: nixbook, a NixOS desktop (niri \
compositor, its own shell "nixbook-shell": bar, dock, notifications, night light, themes, widgets, idle and lock). \
Warm, quick, concrete. Answer in the language the user writes in ({lang} when unsure). Ask ONE short question (what they do on their computer, what bothers \
them, the look they like), with two or three examples to pick from. No configuration yet. {nudge}"""


def emit(kind, **fields):
    sys.stdout.write(json.dumps({"type": kind, **fields}, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# ── The shell's settings, as the model sees them ──
def catalog():
    with open(os.path.join(SETTINGS_LIB, "builtin-defaults.json"), encoding="utf-8") as f:
        tree = json.load(f)
    lines = []

    def walk(prefix, v):
        if isinstance(v, dict) and v:
            for k, sub in v.items():
                walk(f"{prefix}.{k}" if prefix else k, sub)
            return
        s = json.dumps(v, ensure_ascii=False)
        if len(s) > 70:
            s = s[:67] + "…"
        lines.append(f"{prefix} = {s}")

    walk("", tree)
    # The theme ids: an enum the defaults don't show.
    try:
        with open(os.path.join(SETTINGS_LIB, "src", "modules", "common", "themes.json"), encoding="utf-8") as f:
            themes = json.load(f)
        for t in themes.get("themes") or []:
            variants = [v.get("id") for v in t.get("variants") or []]
            lines.append(f"# appearance.theme may be \"{t.get('id')}\"" + (f" (appearance.{t.get('id')}.variant: "
                                                                            f"{', '.join(variants)})" if variants else ""))
    except (OSError, ValueError):
        pass
    return "\n".join(lines)


# ── The model (nixbook_ai: the client every AI script of the shell shares) ──
def masked_post(system, convo, effort):
    """One answer of the provider's main model, through the privacy mask
    like every other AI pass: what the user typed leaves with names,
    emails… as placeholders, and the answer (the configuration included)
    comes back with the real values."""
    p = nixbook_ai.Provider.from_env()
    # Every turn: its earlier answers were unmasked for the user, so they
    # hold the real names too (only the user's used to be masked, and the
    # model's own answers went back to the provider with them).
    sent = [dict(m, content=nixbook_ai.mask(m["content"])) for m in convo]
    text = nixbook_ai.answer(nixbook_ai.mask(system), sent, model="main", effort=effort, max_tokens=8000, provider=p)
    return p.model("main"), nixbook_ai.unmask(text)


def blocks_of(text):
    """The message without the blocks, and the blocks ({name: nix})."""
    found = {}
    for name in BLOCKS:
        m = re.search(rf"<{name}>\s*(.*?)\s*</{name}>", text, re.S)
        if m:
            body = m.group(1).strip()
            body = re.sub(r"^```(?:nix)?\s*|\s*```$", "", body).strip()
            if body and body not in ("{}", "{ }"):
                found[name] = body
    say = re.sub(r"<(%s)>.*?</\1>" % "|".join(BLOCKS), "", text, flags=re.S)
    say = re.sub(r"\n{3,}", "\n\n", say).strip()
    return say, found


# ── Nix ──
def nix_bin(name):
    exe = shutil.which(name) or (os.path.exists(f"/run/current-system/sw/bin/{name}") and f"/run/current-system/sw/bin/{name}")
    if not exe:
        raise RuntimeError(f"{name} isn't installed")
    return exe


def nix_error(stderr):
    """Nix's own message, without the traces and colours."""
    s = re.sub(r"\x1b\[[0-9;]*m", "", stderr or "").strip()
    i = s.rfind("error:")
    msg = s[i:] if i >= 0 else s
    lines = [line.rstrip() for line in msg.splitlines() if not line.strip().startswith("…")]
    out = "\n".join(line for line in lines if line.strip())
    return out[:1500]


def check(found, tmp):
    """(ok, stage, errors, settings JSON or None)."""
    inst = nix_bin("nix-instantiate")
    paths = {}
    for name, body in found.items():
        path = os.path.join(tmp, f"{name}.nix")
        with open(path, "w", encoding="utf-8") as f:
            f.write(body + "\n")
        paths[name] = path
        p = subprocess.run([inst, "--parse", path], capture_output=True, text=True, timeout=60)
        if p.returncode != 0:
            return False, "parse", f"<{name}> doesn't parse:\n{nix_error(p.stderr)}", None
        p = subprocess.run([inst, "--eval", "--expr", f"builtins.typeOf (import {path})"], capture_output=True,
                           text=True, timeout=60)
        if p.returncode != 0 or p.stdout.strip() != '"set"':
            why = nix_error(p.stderr) if p.returncode != 0 else f"it is a {p.stdout.strip()}"
            return False, "parse", f"<{name}> must be a plain attrset ({{ ... }}), no function header: {why}", None
    if "shell" not in paths:
        return True, "type", "", None
    lib_arg = ["--arg", "libDir", NIXPKGS_LIB] if NIXPKGS_LIB else ["--arg", "libDir", "<nixpkgs/lib>"]
    expr = """{ libDir, settingsDir, snippet }:
let
  lib = import libDir;
  shellLib = import (settingsDir + "/lib.nix") { inherit lib; };
  r = lib.evalModules { modules = [ shellLib.settingsModule { config = import snippet; } ]; };
in shellLib.pinnedSettings r.config
"""
    efile = os.path.join(tmp, "check.nix")
    with open(efile, "w", encoding="utf-8") as f:
        f.write(expr)
    p = subprocess.run([inst, "--eval", "--strict", "--json", efile, *lib_arg, "--arg", "settingsDir", SETTINGS_LIB,
                        "--arg", "snippet", paths["shell"]], capture_output=True, text=True, timeout=180)
    if p.returncode != 0:
        return False, "type", f"<shell> fails against the shell's typed options:\n{nix_error(p.stderr)}", None
    try:
        settings = json.loads(p.stdout)
    except ValueError:
        settings = None
    return True, "type", "", settings


def compose(found, host, user):
    parts, where = [], []
    if "shell" in found:
        parts.append("# The shell's settings (Home Manager). nixbook: in profiles/%s/%s/, as\n"
                     "# customHomeManagerModules.nixbookShellConfig.settings; elsewhere programs.nixbook-shell.settings.\n"
                     "customHomeManagerModules.nixbookShellConfig.settings = %s;" % (host or "<host>", user or "<user>",
                                                                                     found["shell"]))
        where.append(f"profiles/{host or '<host>'}/{user or '<user>'}/nixbookShellConfig.nix")
    if "home-manager" in found:
        parts.append("# Home Manager (the user's profile, profiles/%s/%s/):\n%s" % (host or "<host>", user or "<user>",
                                                                                    found["home-manager"]))
        where.append(f"profiles/{host or '<host>'}/{user or '<user>'}/ (Home Manager)")
    if "nixos" in found:
        parts.append("# NixOS (the machine, profiles/%s/configuration.nix):\n%s" % (host or "<host>", found["nixos"]))
        where.append(f"profiles/{host or '<host>'}/configuration.nix")
    return "\n\n".join(parts), ", ".join(where)


def break_for_test(found):
    """NIX_ONBOARD_TEST_BREAK=1: the first draft gets a misspelt key, so the
    fixing loop can be seen at work."""
    if "shell" in found:
        found["shell"] = re.sub(r"^\s*\{", "{\n  notifications.silentt = true;", found["shell"], count=1)
    else:
        found["shell"] = "{ notifications.silentt = true; }"
    return found


# ── A turn ──
def turn(path):
    started = time.monotonic()
    try:
        with open(path, encoding="utf-8") as f:
            req = json.load(f)
    except (OSError, ValueError) as e:
        emit("error", error=f"no request: {e}")
        return 2
    lang = LANGS.get(str(req.get("lang") or "en")[:2].lower(), "English")
    host = str(req.get("host") or socket.gethostname().split(".")[0])
    user = str(req.get("user") or os.environ.get("USER") or "")
    convo = []
    for m in req.get("messages") or []:
        role = "assistant" if m.get("role") == "assistant" else "user"
        if m.get("text"):
            if convo and convo[-1]["role"] == role:
                convo[-1]["content"] += "\n\n" + str(m["text"])
            else:
                convo.append({"role": role, "content": str(m["text"])})
    if not convo or convo[0]["role"] != "user":
        convo.insert(0, {"role": "user", "content": "Hi! Help me set up my desktop."})
    asked = sum(1 for m in convo if m["role"] == "assistant")
    wants_config = asked >= MAX_QUESTIONS or bool(req.get("now")) or bool(re.search(
        r"\b(go|do it|vas-y|fais-le|los|làm đi|write it|generate|that's all|c'est tout|apply)\b",
        convo[-1]["content"], re.I)) or asked >= 2
    try:
        if not wants_config:
            # A question: a short prompt, quick.
            nudge = "This is question %d of at most %d." % (asked + 1, MAX_QUESTIONS)
            _, text = masked_post(QUESTION_SYSTEM.format(lang=lang, nudge=nudge), convo, "low")
            emit("say", text=text.strip())
            emit("done", ms=int((time.monotonic() - started) * 1000))
            return 0
        system = SYSTEM.format(lang=lang, max_q=MAX_QUESTIONS, catalog=catalog())
        if asked >= MAX_QUESTIONS or req.get("now"):
            convo[-1]["content"] += "\n\n(Write the configuration now.)"
        _, text = masked_post(system, convo, "low")
        say, found = blocks_of(text)
        if not found:
            # Still a question (it wanted to know more): fine.
            emit("say", text=say or text.strip())
            emit("done", ms=int((time.monotonic() - started) * 1000))
            return 0
        emit("say", text=say)
        if os.environ.get("NIX_ONBOARD_TEST_BREAK") == "1":
            found = break_for_test(found)
        tmp = tempfile.mkdtemp(prefix="nix-onboard-")
        try:
            ok, settings = False, None
            for rnd in range(MAX_FIXES + 1):
                t0 = time.monotonic()
                emit("checking", round=rnd + 1)
                ok, stage, errors, settings = check(found, tmp)
                emit("check", round=rnd + 1, ok=ok, stage=stage, errors=errors,
                     ms=int((time.monotonic() - t0) * 1000))
                if ok or rnd == MAX_FIXES:
                    break
                convo.append({"role": "assistant", "content": text})
                convo.append({"role": "user", "content": (
                    "Checking it with Nix failed:\n" + errors + "\n\nFix it: answer with one short line saying what "
                    "you changed, then ALL the blocks again, corrected (only keys of the list, their types).")})
                _, text = masked_post(system, convo, "low")
                note, fixed = blocks_of(text)
                if fixed:
                    found = fixed
                if note:
                    emit("fix", round=rnd + 1, text=note)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        nix, where = compose(found, host, user)
        emit("config", nix=nix, where=where, explanation=say, checked=ok, shell="shell" in found,
             settings=settings, blocks=list(found))
    except Exception as e:  # noqa: BLE001 — every failure is the window's to show
        emit("error", error=str(e) or e.__class__.__name__)
        emit("done", ms=int((time.monotonic() - started) * 1000))
        return 1
    emit("done", ms=int((time.monotonic() - started) * 1000))
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "turn":
        # The key: the environment's, else `nixbook-model-provider env`; run
        # again through `run` only when that fails.
        nixbook_ai.use_caps_cache()
        try:
            nixbook_ai.Provider.from_env()
        except nixbook_ai.AIError as e:
            nixbook_ai.ensure_provider(argv[1:], __file__, why=str(e))
        return turn(argv[2])
    if len(argv) == 2 and argv[1] == "catalog":
        print(catalog())
        return 0
    if len(argv) == 3 and argv[1] == "check":
        # A shell settings snippet (a file), checked alone.
        with open(argv[2], encoding="utf-8") as f:
            body = f.read()
        tmp = tempfile.mkdtemp(prefix="nix-onboard-")
        try:
            ok, stage, errors, settings = check({"shell": body}, tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        print(json.dumps({"ok": ok, "stage": stage, "errors": errors, "settings": settings}, ensure_ascii=False))
        return 0 if ok else 1
    print("usage: nixbook-nix-onboard turn REQUEST.json | check SETTINGS.nix | catalog", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
