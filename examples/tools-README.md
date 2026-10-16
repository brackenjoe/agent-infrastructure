# tools

Every tool and how to invoke it. Agents read this before building something
that may already exist; `tools/check-repo.sh` fails if a file in `tools/`
has no row here.

| Tool | What it does and how to run it |
|---|---|
| `check-repo.sh` | The repo's own rules, checked by script. `tools/check-repo.sh`; exit 1 on any FAIL. Part of finishing every job. |
| `public-scan.sh` | The gate before any push to a public remote. `tools/public-scan.sh DIR`. Pass or fail, each hit printed with file and line. Does not replace reading the diff. |
| `public-scan.deny` | Private terms the scanner fails on, one per line. Never published. |
| `deploy-<app>.sh` | Push one app to its host and verify it: stage, install, restart, run the remote selftest, fetch the page. `tools/deploy-<app>.sh [HOST]`. |
