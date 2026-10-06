#!/usr/bin/env python3
"""Launches the app against made-up sessions: for screenshots and UI work without exposing real projects.

    python3 scripts/demo.py [path/to/AgentsVisualizer [app arguments…]]   # default: the binary in build/*.app
    python3 scripts/demo.py "build/Claude Code Agents Visualizer.app/Contents/MacOS/AgentsVisualizer" -AppleLanguages "(en)"

Writes a fake `~/.claude` and Claude Desktop session index into a temporary directory, keeps "live" sessions
alive with `sleep` processes (the dashboard checks that registered PIDs are running), and cleans everything up
when the app quits.
"""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

NOW = time.time()


def iso(offset):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(NOW + offset)) + ".000Z"


def user(text, offset, cwd, branch="main"):
    return {"type": "user", "timestamp": iso(offset), "cwd": cwd, "gitBranch": branch,
            "message": {"role": "user", "content": text}}


def tool(name, tool_input, offset, mid="m1", model="claude-opus-5-5"):
    return {"type": "assistant", "timestamp": iso(offset),
            "message": {"id": mid, "role": "assistant", "stop_reason": "tool_use", "model": model,
                        "content": [{"type": "tool_use", "id": "t1", "name": name, "input": tool_input}]}}


def done(text, offset, mid="m2", model="claude-opus-5-5"):
    return {"type": "assistant", "timestamp": iso(offset),
            "message": {"id": mid, "role": "assistant", "stop_reason": "end_turn", "model": model,
                        "content": [{"type": "text", "text": text}]}}


# (project, title, status, surface, minutes ago, activity tool, agents [(type, description, state, minutes)], extras)
HOME = "/Users/you/code"
SESSIONS = [
    ("acme-web", "Add dark mode to settings", "busy", "desktop", 0, ("Edit", {"file_path": "SettingsView.swift"}), [
        ("Explore", "Find every theme token", "running", 3),
        ("code-reviewer", "Review color contrast", "running", 1),
        ("general-purpose", "Update UI snapshots", "done", 6),
    ], {}),
    ("acme-web", "Fix flaky checkout test", "waiting", "cli", 1, None, [], {"waitingFor": "permission prompt"}),
    ("acme-web", "Upgrade to React 20", "idle", "desktop", 25, None, [], {"pr": (128, "OPEN")}),
    ("payments-api", "Idempotent refunds", "busy", "desktop", 0, ("Bash", {"description": "Run the integration tests"}), [
        ("code-reviewer", "Concurrency review", "running", 2),
    ], {"worktree": "brave-otter", "pr": (42, "OPEN")}),
    ("payments-api", "Postgres 17 migration plan", "idle", "desktop", 48, None, [], {"branch": "chore/pg17"}),
    ("mobile-app", "Release notes for 3.2", "idle", "desktop", 12, None, [], {"pr": (311, "MERGED")}),
    ("mobile-app", "Crash in onboarding flow", "ended", "cli", 190, None, [], {}),
    ("infra", "Terraform drift check", "ended", "cli", 320, None, [], {}),
]


def main():
    # Turn SIGTERM/SIGHUP into a normal exit so the `finally` below still stops the holders and deletes the data.
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda *_: sys.exit(0))
    root = pathlib.Path(tempfile.mkdtemp(prefix="agents-visualizer-demo-"))
    claude = root / ".claude"
    desktop = root / "desktop" / "account" / "org"
    holders = []
    try:
        for project, title, status, surface, minutes, activity, agents, extra in SESSIONS:
            sid = str(uuid.uuid4())
            cwd = f"{HOME}/{project}"
            if "worktree" in extra:
                cwd += f"/.claude/worktrees/{extra['worktree']}"
            branch = extra.get("branch", f"worktree-{extra['worktree']}" if "worktree" in extra else "main")
            ago = -minutes * 60
            lines = [user(title, ago - 600, cwd, branch), {"type": "custom-title", "customTitle": title}]
            lines.append(tool(*activity, ago) if activity else done("Done.", ago))
            pdir = claude / "projects" / f"-Users-you-code-{project}"
            pdir.mkdir(parents=True, exist_ok=True)
            (pdir / f"{sid}.jsonl").write_text("\n".join(json.dumps(l) for l in lines) + "\n")

            for index, (agent_type, description, state, started) in enumerate(agents):
                adir = pdir / sid / "subagents"
                adir.mkdir(parents=True, exist_ok=True)
                aid = f"a{index}{uuid.uuid4().hex[:12]}"
                (adir / f"agent-{aid}.meta.json").write_text(json.dumps(
                    {"agentType": agent_type, "description": description, "requestShape": "background"}))
                body = [user(description, -started * 60, cwd)]
                # Running agents must have written after their session's process registered (it is spawned below);
                # older entries would count as cut off by a previous process.
                agent_model = "claude-haiku-4-5" if agent_type == "Explore" else "claude-sonnet-5-5"
                body.append(tool("Grep", {"pattern": "--color-"}, 5, model=agent_model) if state == "running"
                            else done("Done.", -60, model=agent_model))
                (adir / f"agent-{aid}.jsonl").write_text("\n".join(json.dumps(l) for l in body) + "\n")

            if surface == "desktop":
                desktop.mkdir(parents=True, exist_ok=True)
                record = {"sessionId": f"local_{uuid.uuid4()}", "cliSessionId": sid, "cwd": cwd, "title": title,
                          "isArchived": False, "createdAt": (NOW - 3600) * 1000, "lastActivityAt": (NOW + ago) * 1000,
                          "model": "claude-opus-5-5", "effort": "xhigh" if status == "busy" else "high"}
                if "branch" in extra:
                    record["branch"] = extra["branch"]
                if "pr" in extra:
                    number, state = extra["pr"]
                    record["prs"] = [{"prNumber": number, "url": f"https://github.com/acme/{project}/pull/{number}",
                                      "state": state}]
                (desktop / f"{record['sessionId']}.json").write_text(json.dumps(record))

            if status != "ended":
                holder = subprocess.Popen(["sleep", "86400"], start_new_session=True)
                holders.append(holder)
                registry = claude / "sessions"
                registry.mkdir(parents=True, exist_ok=True)
                (registry / f"{holder.pid}.json").write_text(json.dumps({
                    "pid": holder.pid, "sessionId": sid, "cwd": cwd, "startedAt": time.time() * 1000 + 1000,
                    "kind": "interactive", "entrypoint": "claude-desktop" if surface == "desktop" else "cli",
                    "status": status, "waitingFor": extra.get("waitingFor"),
                    "statusUpdatedAt": (NOW + ago) * 1000}))

        repo = pathlib.Path(__file__).resolve().parent.parent
        binary = sys.argv[1] if len(sys.argv) > 1 else str(
            repo / "build" / "Claude Code Agents Visualizer.app" / "Contents" / "MacOS" / "AgentsVisualizer")
        env = dict(os.environ, CLAUDE_CONFIG_DIR=str(claude),
                   AGENTS_VISUALIZER_DESKTOP_SESSIONS_DIR=str(root / "desktop"))
        print(f"Demo data in {root}; quit the app to clean up.", flush=True)
        subprocess.run([binary, *sys.argv[2:]], env=env)
    except KeyboardInterrupt:
        pass
    finally:
        for holder in holders:
            holder.send_signal(signal.SIGTERM)
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
