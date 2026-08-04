# noctel-gitops Claude Code Guide

## K3s Node Access

Access k3s cluster nodes via SSH using:
```bash
ssh $hostip $cmd
```

**Example:**
```bash
ssh 10.0.96.25 "cat /etc/hosts"
ssh 10.0.96.26 "ip route"
```

Do NOT specify a username—use the node IP directly.

## Git Commit Messages

Never add `Co-Authored-By: Claude` to commit messages. Commits should represent only human authorship.

## Memory System

Auto-memory is stored in `/Users/finbar.day/.claude/projects/-Users-finbar-day-Documents-BitBucket-noctel-gitops/memory/`.
Keep memory updated with:
- Project status and deadlines
- Known issues and their workarounds
- Architecture decisions and rationale

Make sure to keep aware of 
*/*.md
and 
*.md
These are the files that we track memory in for general processes, projects, current status and fixes. 
