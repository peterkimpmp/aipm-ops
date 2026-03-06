from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

REQUIRED_SCRIPTS = [
    "check-pm-integrity.sh",
    "issue-create.sh",
    "issue-log.sh",
    "pm-close.sh",
    "pm-modernize.sh",
    "pm-start.sh",
    "pm-state.sh",
    "pm-sync.sh",
    "setup-labels.sh",
]


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _write_fake_gh(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
from __future__ import annotations
import json, os, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(os.environ["FAKE_GH_STATE"])

def load():
    return json.loads(state_path.read_text(encoding="utf-8"))

def save(data):
    state_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\\n", encoding="utf-8")

def now():
    return datetime.now(timezone.utc).isoformat()

def arg_value(args, flag, default=""):
    if flag not in args:
        return default
    idx = args.index(flag)
    return args[idx + 1]

def collect_multi(args, flag):
    values = []
    idx = 0
    while idx < len(args):
        if args[idx] == flag:
            values.append(args[idx + 1])
            idx += 2
        else:
            idx += 1
    return values

def apply_jq(payload, expr):
    proc = subprocess.run(
        ["jq", "-r", expr],
        input=json.dumps(payload, ensure_ascii=False).encode(),
        check=True,
        capture_output=True,
    )
    sys.stdout.write(proc.stdout.decode())

args = sys.argv[1:]
if args[:2] == ["repo", "view"]:
    data = load()
    payload = {"nameWithOwner": data["repo"]}
    if "--jq" in args:
        apply_jq(payload, arg_value(args, "--jq"))
    else:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(0)

if args[:2] == ["label", "list"]:
    data = load()
    payload = [{"name": name} for name in data.get("labels", [])]
    if "--jq" in args:
        apply_jq(payload, arg_value(args, "--jq"))
    else:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(0)

if args[:2] == ["issue", "create"]:
    data = load()
    title = arg_value(args, "--title")
    body = arg_value(args, "--body", "")
    body_file = arg_value(args, "--body-file", "")
    if body_file:
      body = Path(body_file).read_text(encoding="utf-8")
    labels = collect_multi(args, "--label")
    number = int(data.get("next_issue", 1))
    issue = {
        "number": number,
        "title": title,
        "body": body,
        "state": "OPEN",
        "url": f"https://github.com/{data['repo']}/issues/{number}",
        "labels": labels,
        "comments": [],
        "updatedAt": now(),
    }
    data.setdefault("issues", []).append(issue)
    data["next_issue"] = number + 1
    save(data)
    print(issue["url"])
    raise SystemExit(0)

if args[:2] == ["issue", "list"]:
    data = load()
    state = arg_value(args, "--state", "open").lower()
    issues = data.get("issues", [])
    filtered = []
    for issue in issues:
        if state == "all" or issue["state"].lower() == state:
            filtered.append(issue)
    payload = []
    for issue in filtered:
        payload.append(
            {
                "number": issue["number"],
                "title": issue["title"],
                "state": issue["state"],
                "url": issue["url"],
                "updatedAt": issue.get("updatedAt", now()),
                "labels": [{"name": label} for label in issue.get("labels", [])],
            }
        )
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(0)

if args[:2] == ["issue", "view"]:
    data = load()
    issue_number = int(args[2])
    issue = next(item for item in data.get("issues", []) if int(item["number"]) == issue_number)
    payload = {
        "number": issue["number"],
        "title": issue["title"],
        "body": issue.get("body", ""),
        "state": issue["state"],
        "url": issue["url"],
        "labels": [{"name": label} for label in issue.get("labels", [])],
        "comments": issue.get("comments", []),
    }
    if "--jq" in args:
        apply_jq(payload, arg_value(args, "--jq"))
    else:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(0)

if args[:2] == ["issue", "edit"]:
    data = load()
    issue_number = int(args[2])
    issue = next(item for item in data.get("issues", []) if int(item["number"]) == issue_number)
    add_labels = collect_multi(args, "--add-label")
    remove_labels = collect_multi(args, "--remove-label")
    labels = [label for label in issue.get("labels", []) if label not in remove_labels]
    for label in add_labels:
        if label not in labels:
            labels.append(label)
    issue["labels"] = labels
    issue["updatedAt"] = now()
    save(data)
    raise SystemExit(0)

if args[:2] == ["issue", "comment"]:
    data = load()
    issue_number = int(args[2])
    issue = next(item for item in data.get("issues", []) if int(item["number"]) == issue_number)
    body = arg_value(args, "--body")
    issue.setdefault("comments", []).append({"body": body, "createdAt": now()})
    issue["updatedAt"] = now()
    save(data)
    print(f"https://github.com/{data['repo']}/issues/{issue_number}#comment")
    raise SystemExit(0)

if args[:2] == ["issue", "close"]:
    data = load()
    issue_number = int(args[2])
    issue = next(item for item in data.get("issues", []) if int(item["number"]) == issue_number)
    issue["state"] = "CLOSED"
    issue["updatedAt"] = now()
    save(data)
    print(f"Closed issue #{issue_number}")
    raise SystemExit(0)

if args[:2] == ["pr", "list"]:
    data = load()
    state = arg_value(args, "--state", "open").upper()
    search = arg_value(args, "--search", "")
    payload = []
    for pr in data.get("prs", []):
        if pr.get("state", "").upper() != state:
            continue
        haystack = f"{pr.get('title', '')}\\n{pr.get('body', '')}"
        if search and search not in haystack:
            continue
        payload.append(pr)
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(0)

if args[:2] == ["pr", "create"]:
    data = load()
    title = arg_value(args, "--title")
    body = arg_value(args, "--body", "")
    body_file = arg_value(args, "--body-file", "")
    if body_file:
        body = Path(body_file).read_text(encoding="utf-8")
    number = int(data.get("next_pr", 1))
    pr = {
        "number": number,
        "title": title,
        "body": body,
        "url": f"https://github.com/{data['repo']}/pull/{number}",
        "mergedAt": None,
        "state": "OPEN",
    }
    data.setdefault("prs", []).append(pr)
    data["next_pr"] = number + 1
    save(data)
    print(pr["url"])
    raise SystemExit(0)

if args[:2] == ["pr", "merge"]:
    data = load()
    pr_number = int(args[2])
    pr = next(item for item in data.get("prs", []) if int(item["number"]) == pr_number)
    pr["state"] = "MERGED"
    pr["mergedAt"] = now()
    save(data)
    print(f"Merged pull request #{pr_number}")
    raise SystemExit(0)

raise SystemExit(f"unsupported gh invocation: {' '.join(args)}")
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def _make_repo(tmp_path: Path, gh_state: dict) -> tuple[Path, Path]:
    repo = tmp_path / "repo"
    repo.mkdir()
    scripts_dir = repo / "scripts"
    scripts_dir.mkdir()
    for rel in REQUIRED_SCRIPTS:
        shutil.copy2(_repo_root() / "scripts" / rel, scripts_dir / rel)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_fake_gh(fake_bin / "gh")
    state_path = tmp_path / "gh-state.json"
    state_path.write_text(
        json.dumps(gh_state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "pm@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "PM Bot"], cwd=repo, check=True)
    aipm_dir = repo / ".aipm"
    aipm_dir.mkdir()
    (aipm_dir / "ops.env").write_text("ISSUE_KEY_PREFIX=PP\n", encoding="utf-8")
    (repo / "README.md").write_text("test repo\n", encoding="utf-8")
    subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=repo, check=True, capture_output=True)
    remote = tmp_path / "origin.git"
    subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
    subprocess.run(["git", "remote", "add", "origin", str(remote)], cwd=repo, check=True)
    subprocess.run(["git", "push", "-u", "origin", "main"], cwd=repo, check=True, capture_output=True)
    return repo, state_path


def _run(repo: Path, state_path: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PATH"] = f"{state_path.parent / 'bin'}:{env['PATH']}"
    env["FAKE_GH_STATE"] = str(state_path)
    return subprocess.run(
        list(args),
        cwd=repo,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_pm_start_writes_active_issue_state_and_in_progress_label(tmp_path: Path):
    repo, state_path = _make_repo(
        tmp_path,
        {
            "repo": "owner/repo",
            "next_issue": 1,
            "next_pr": 1,
            "issues": [],
            "prs": [],
            "labels": ["type:task", "status:todo", "status:in-progress", "area:aipm"],
        },
    )

    proc = _run(
        repo,
        state_path,
        "bash",
        "scripts/pm-start.sh",
        "--title",
        "[Task] Demo flow",
        "--label",
        "area:aipm",
        "--body",
        "scope",
    )
    assert proc.returncode == 0, proc.stderr
    active = json.loads((repo / ".aipm/state/active-issue.json").read_text(encoding="utf-8"))
    assert active["issue"] == 1
    assert active["status"] == "in_progress"
    assert active["branch"].startswith("task/PP-1-demo-flow")
    assert active["result_file"] == "docs/results/result-1-demo-flow.md"

    gh_state = json.loads(state_path.read_text(encoding="utf-8"))
    issue = gh_state["issues"][0]
    assert "status:in-progress" in issue["labels"]
    assert "status:todo" not in issue["labels"]


def test_pm_sync_discovers_recent_issue_without_active_state(tmp_path: Path):
    repo, state_path = _make_repo(
        tmp_path,
        {
            "repo": "owner/repo",
            "next_issue": 2,
            "next_pr": 1,
            "issues": [
                {
                    "number": 1,
                    "title": "[Task] Existing flow",
                    "body": "body",
                    "state": "OPEN",
                    "url": "https://github.com/owner/repo/issues/1",
                    "labels": ["type:task", "status:in-progress"],
                    "updatedAt": "2026-03-06T00:00:00+00:00",
                    "comments": [
                        {"body": "### START | PP-1\nx", "createdAt": "2026-03-06T00:00:00+00:00"},
                        {"body": "### PLAN | PP-1\nx", "createdAt": "2026-03-06T00:01:00+00:00"},
                        {
                            "body": "### PROGRESS | PP-1\nx",
                            "createdAt": "2026-03-06T00:02:00+00:00",
                        },
                    ],
                }
            ],
            "prs": [],
            "labels": ["type:task", "status:in-progress"],
        },
    )

    proc = _run(repo, state_path, "bash", "scripts/pm-sync.sh", "--json")
    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    assert payload["source"] == "discovered"
    assert payload["issue"]["number"] == 1
    assert payload["state"] == "healthy"


def test_pm_close_from_active_archives_state_and_marks_done(tmp_path: Path):
    repo, state_path = _make_repo(
        tmp_path,
        {
            "repo": "owner/repo",
            "next_issue": 2,
            "next_pr": 11,
            "issues": [
                {
                    "number": 1,
                    "title": "[Task] Close flow",
                    "body": "body",
                    "state": "OPEN",
                    "url": "https://github.com/owner/repo/issues/1",
                    "labels": ["type:task", "status:in-progress"],
                    "updatedAt": "2026-03-06T00:00:00+00:00",
                    "comments": [],
                }
            ],
            "prs": [
                {
                    "number": 10,
                    "title": "PR",
                    "body": "Closes #1",
                    "url": "https://github.com/owner/repo/pull/10",
                    "mergedAt": "2026-03-06T00:10:00+00:00",
                    "state": "MERGED",
                }
            ],
            "labels": ["type:task", "status:in-progress", "status:done"],
        },
    )
    state_dir = repo / ".aipm/state"
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "active-issue.json").write_text(
        json.dumps(
            {
                "issue": 1,
                "title": "[Task] Close flow",
                "branch": "main",
                "worktree": str(repo),
                "repo": "owner/repo",
                "started_at": "2026-03-06T00:00:00+00:00",
                "updated_at": "2026-03-06T00:00:00+00:00",
                "start_file": "",
                "plan_file": "",
                "progress_file": "",
                "result_file": "docs/results/result-1-close-flow.md",
                "status": "in_progress",
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    result_path = repo / "docs/results/result-1-close-flow.md"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text("# Result\n\n## 현행화\n\n- done\n", encoding="utf-8")

    proc = _run(repo, state_path, "bash", "scripts/pm-close.sh", "--from-active", "--yes")
    assert proc.returncode == 0, proc.stderr
    assert not (state_dir / "active-issue.json").exists()
    assert (state_dir / "active-issue.last.json").exists()
    assert (state_dir / "modernized-1.flag").exists()

    gh_state = json.loads(state_path.read_text(encoding="utf-8"))
    issue = gh_state["issues"][0]
    assert issue["state"] == "CLOSED"
    assert "status:done" in issue["labels"]
    assert "status:in-progress" not in issue["labels"]


def test_pm_close_auto_lands_branch_before_close(tmp_path: Path):
    repo, state_path = _make_repo(
        tmp_path,
        {
            "repo": "owner/repo",
            "next_issue": 2,
            "next_pr": 1,
            "issues": [
                {
                    "number": 1,
                    "title": "[Task] Land flow",
                    "body": "body",
                    "state": "OPEN",
                    "url": "https://github.com/owner/repo/issues/1",
                    "labels": ["type:task", "status:in-progress"],
                    "updatedAt": "2026-03-06T00:00:00+00:00",
                    "comments": [],
                }
            ],
            "prs": [],
            "labels": ["type:task", "status:in-progress", "status:done"],
        },
    )
    subprocess.run(
        ["git", "checkout", "-b", "task/PP-1-land-flow"], cwd=repo, check=True, capture_output=True
    )
    (repo / "feature.txt").write_text("land me\n", encoding="utf-8")

    state_dir = repo / ".aipm/state"
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "active-issue.json").write_text(
        json.dumps(
            {
                "issue": 1,
                "title": "[Task] Land flow",
                "branch": "task/PP-1-land-flow",
                "worktree": str(repo),
                "repo": "owner/repo",
                "started_at": "2026-03-06T00:00:00+00:00",
                "updated_at": "2026-03-06T00:00:00+00:00",
                "start_file": "",
                "plan_file": "",
                "progress_file": "",
                "result_file": "docs/results/result-1-land-flow.md",
                "status": "in_progress",
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    result_path = repo / "docs/results/result-1-land-flow.md"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text("# Result\n\n## 현행화\n\n- done\n", encoding="utf-8")

    proc = _run(repo, state_path, "bash", "scripts/pm-close.sh", "--from-active", "--yes")
    assert proc.returncode == 0, proc.stderr

    gh_state = json.loads(state_path.read_text(encoding="utf-8"))
    assert gh_state["issues"][0]["state"] == "CLOSED"
    assert gh_state["prs"][0]["state"] == "MERGED"
    assert (state_dir / "modernized-1.flag").exists()

    subprocess.run(["git", "checkout", "main"], cwd=repo, check=True, capture_output=True)
    log = subprocess.run(
        ["git", "log", "--oneline", "--", "feature.txt"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    assert "land closeout branch" in log.stdout


def test_pm_close_requires_result_file_in_active_worktree(tmp_path: Path):
    repo, state_path = _make_repo(
        tmp_path,
        {
            "repo": "owner/repo",
            "next_issue": 2,
            "next_pr": 1,
            "issues": [
                {
                    "number": 1,
                    "title": "[Task] Split worktree flow",
                    "body": "body",
                    "state": "OPEN",
                    "url": "https://github.com/owner/repo/issues/1",
                    "labels": ["type:task", "status:in-progress"],
                    "updatedAt": "2026-03-06T00:00:00+00:00",
                    "comments": [],
                }
            ],
            "prs": [],
            "labels": ["type:task", "status:in-progress", "status:done"],
        },
    )
    subprocess.run(
        ["git", "branch", "task/PP-1-split-worktree-flow"],
        cwd=repo,
        check=True,
        capture_output=True,
    )
    active_worktree = tmp_path / "active-worktree"
    subprocess.run(
        ["git", "worktree", "add", str(active_worktree), "task/PP-1-split-worktree-flow"],
        cwd=repo,
        check=True,
        capture_output=True,
    )

    state_dir = repo / ".aipm/state"
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "active-issue.json").write_text(
        json.dumps(
            {
                "issue": 1,
                "title": "[Task] Split worktree flow",
                "branch": "task/PP-1-split-worktree-flow",
                "worktree": str(active_worktree),
                "repo": "owner/repo",
                "started_at": "2026-03-06T00:00:00+00:00",
                "updated_at": "2026-03-06T00:00:00+00:00",
                "start_file": "",
                "plan_file": "",
                "progress_file": "",
                "result_file": "docs/results/result-1-split-worktree-flow.md",
                "status": "in_progress",
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    result_path = repo / "docs/results/result-1-split-worktree-flow.md"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text("# Result\n\n## 현행화\n\n- done\n", encoding="utf-8")

    proc = _run(repo, state_path, "bash", "scripts/pm-close.sh", "--from-active", "--yes")
    assert proc.returncode == 2
    assert "blocker=result_file_not_in_active_worktree:docs/results/result-1-split-worktree-flow.md" in proc.stderr


def test_check_pm_integrity_fix_active_repairs_missing_status(tmp_path: Path):
    repo, state_path = _make_repo(
        tmp_path,
        {
            "repo": "owner/repo",
            "next_issue": 2,
            "next_pr": 1,
            "issues": [
                {
                    "number": 1,
                    "title": "[Task] Missing status",
                    "body": "body",
                    "state": "OPEN",
                    "url": "https://github.com/owner/repo/issues/1",
                    "labels": ["type:task"],
                    "updatedAt": "2026-03-06T00:00:00+00:00",
                    "comments": [],
                }
            ],
            "prs": [],
            "labels": ["type:task", "status:in-progress", "status:done"],
        },
    )
    state_dir = repo / ".aipm/state"
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "active-issue.json").write_text(
        json.dumps({"issue": 1}, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    proc = _run(
        repo, state_path, "bash", "scripts/check-pm-integrity.sh", "--state", "open", "--fix-active"
    )
    assert proc.returncode == 0, proc.stderr
    gh_state = json.loads(state_path.read_text(encoding="utf-8"))
    assert "status:in-progress" in gh_state["issues"][0]["labels"]
