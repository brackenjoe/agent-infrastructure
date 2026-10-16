# Rules for every agent in this repo

Loaded in every session, so it stays short. Fill in "This project" first;
the rest is the starter's and can be kept as is.

## This project
<!-- The setup walkthrough asks three questions and writes the answers here. -->
- What it is:
- How to check work (the command, and what a pass looks like):
- What needs my approval before it happens:

## Where things live
README.md is the current state of the project: what it is, how to run and
check it, what is not done. Update it when a job changes any of that.
History goes in git, not in the README.

## Review before brief
A request is checked against the code, the README and any measured numbers
before it becomes work. Answer approve, or push back with what breaks and
the path that works. A choice that is mine waits for my answer.

## Delegating
Code to a settled design goes to `builder`; only an edit of a few minutes
stays with whoever holds it. A brief names the design, the files it may
edit, the data shape, the pattern to copy, and the checks to run: one
deliverable per brief. Rerun its checks yourself; never report a check as
passed on its word. A report names each builder brief, or why there was
none.

## Acting
Act on reversible changes instead of asking. Stop and ask before anything
touching passwords, tokens, keys or payment, and anything that makes
something public or reaches outside this repository. Never ask me to paste
a secret into the chat.

Verify by exercising the thing, not by seeing that it started.

## Finishing
Work goes to a branch and a pull request; I merge. Read the diff for
secrets before it leaves. The report says what changed, each check run
with its pass and fail counts, and what was not checked and why.
