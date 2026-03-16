#!/usr/bin/env python3
"""Extract and format Claude Code session logs from JSONL files.

Usage:
  python3 scripts/claude-session-log.py <session-id-or-path>
  python3 scripts/claude-session-log.py -f <session-id-or-path>   # follow (like tail -f)
  python3 scripts/claude-session-log.py 90ef6d3d-aae7-4e66-8302-0a1d3701981f
  python3 scripts/claude-session-log.py ~/.claude/projects/.../session.jsonl
"""

import json
import sys
import os
import glob
import time
import textwrap

BLUE = "\033[34m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
CYAN = "\033[36m"
DIM = "\033[2m"
BOLD = "\033[1m"
RESET = "\033[0m"


def find_session_file(arg):
    if os.path.isfile(arg):
        return arg
    # Search by session ID across all project dirs
    pattern = os.path.expanduser(f"~/.claude/projects/*/{arg}.jsonl")
    matches = glob.glob(pattern)
    if matches:
        return matches[0]
    # Try partial match
    pattern = os.path.expanduser(f"~/.claude/projects/*/{arg}*.jsonl")
    matches = glob.glob(pattern)
    if matches:
        return sorted(matches, key=os.path.getmtime, reverse=True)[0]
    return None


def truncate(text, max_len=500):
    if len(text) <= max_len:
        return text
    return text[:max_len] + f"{DIM}... ({len(text)} chars total){RESET}"


def format_tool_input(name, inp):
    if name == "Bash":
        cmd = inp.get("command", "")
        desc = inp.get("description", "")
        if desc:
            return f"{DIM}# {desc}{RESET}\n$ {cmd}"
        return f"$ {cmd}"
    if name == "Read":
        path = inp.get("file_path", "")
        parts = []
        if inp.get("offset"):
            parts.append(f"offset={inp['offset']}")
        if inp.get("limit"):
            parts.append(f"limit={inp['limit']}")
        extra = f" ({', '.join(parts)})" if parts else ""
        return f"{path}{extra}"
    if name == "Write":
        path = inp.get("file_path", "")
        content = inp.get("content", "")
        return f"{path} ({len(content)} chars)"
    if name == "Edit":
        path = inp.get("file_path", "")
        old = inp.get("old_string", "")
        new = inp.get("new_string", "")
        return f"{path}\n{DIM}-{RESET} {truncate(old, 120)}\n{DIM}+{RESET} {truncate(new, 120)}"
    if name == "Grep":
        pattern = inp.get("pattern", "")
        path = inp.get("path", "")
        return f"/{pattern}/ in {path}"
    if name == "Glob":
        return inp.get("pattern", str(inp))
    if name in ("ToolSearch", "Skill"):
        return json.dumps(inp)
    # MCP tools
    return json.dumps(inp, indent=2)[:400]


def format_tool_result(text, max_len=300):
    if not text:
        return f"{DIM}(empty){RESET}"
    lines = text.strip().split("\n")
    if len(lines) <= 8 and len(text) <= max_len:
        return text
    shown = "\n".join(lines[:8])
    if len(shown) > max_len:
        shown = shown[:max_len]
    remaining = len(lines) - 8
    if remaining > 0:
        return f"{shown}\n{DIM}... +{remaining} more lines{RESET}"
    return shown


def process_line(line, state):
    """Process a single JSONL line. Returns updated state."""
    line = line.strip()
    if not line:
        return state

    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        return state

    msg = d.get("message", d)
    role = msg.get("role", d.get("type", ""))
    content = msg.get("content", [])

    if not isinstance(content, list):
        return state

    for c in content:
        if not isinstance(c, dict):
            continue

        ctype = c.get("type", "")

        if ctype == "text" and role == "user":
            state["turn"] += 1
            print(f"\n{BOLD}{'='*70}{RESET}")
            print(f"{BOLD}{BLUE}USER (turn {state['turn']}){RESET}")
            print(f"{'='*70}")
            print(c["text"])
            print()

        elif ctype == "text" and role == "assistant":
            print(f"{BOLD}{GREEN}CLAUDE:{RESET}")
            print(c["text"])
            print()

        elif ctype == "tool_use":
            name = c.get("name", "?")
            inp = c.get("input", {})
            if name.startswith("mcp__"):
                short = name.replace("mcp__symphony-tracker__", "plane:")
                print(f"  {CYAN}▸ {short}{RESET}")
            else:
                print(f"  {YELLOW}▸ {name}{RESET}")
            formatted = format_tool_input(name, inp)
            for fline in formatted.split("\n"):
                print(f"    {fline}")
            print()

        elif ctype == "tool_result":
            txt = c.get("content", "")
            if isinstance(txt, list):
                txt = "\n".join(
                    x.get("text", "") for x in txt if isinstance(x, dict)
                )
            is_error = c.get("is_error", False)
            if is_error:
                print(f"    {RED}✗ {format_tool_result(str(txt))}{RESET}")
            else:
                result = format_tool_result(str(txt))
                for fline in result.split("\n"):
                    print(f"    {DIM}{fline}{RESET}")
            print()

    return state


def main():
    args = sys.argv[1:]
    follow = False

    if not args:
        print(__doc__)
        sys.exit(1)

    if args[0] in ("-f", "--follow"):
        follow = True
        args = args[1:]

    if not args:
        print(__doc__)
        sys.exit(1)

    path = find_session_file(args[0])
    if not path:
        print(f"Session not found: {args[0]}")
        sys.exit(1)

    print(f"{DIM}Session: {path}{RESET}")
    if follow:
        print(f"{DIM}Following... (Ctrl+C to stop){RESET}")
    print()

    state = {"turn": 0}

    with open(path) as f:
        for line in f:
            state = process_line(line, state)

        if not follow:
            print(f"\n{DIM}--- end of session ({state['turn']} user turns) ---{RESET}")
            return

        # Follow mode: poll for new lines
        try:
            while True:
                line = f.readline()
                if line:
                    state = process_line(line, state)
                else:
                    time.sleep(0.5)
        except KeyboardInterrupt:
            print(f"\n{DIM}--- stopped ({state['turn']} user turns) ---{RESET}")


if __name__ == "__main__":
    main()
