# Git Workflow & Repository Hygiene Rules

## 1. User-Only Staging Invariant (Strictly NO `git add`)

- The AI assistant **MUST NEVER** execute `git add`, `git rm`, or any command that modifies the Git staging area / index.
- **Staging changes is strictly reserved for the human user.**
- All code modifications, bug fixes, refactorings, or documentation updates made by the assistant must remain in the working tree as unstaged changes.

## 2. Explicit Commit Sign-Off Invariant

- The AI assistant **MUST NEVER** execute `git commit` autonomously.
- Commits may only happen after the human user explicitly gives sign-off to proceed with committing.
- The assistant must never assume permission to commit based on tests passing or work being finished.

## 3. Commit Message Sign-Off & Proposal Workflow

- When a unit of work is completed, compiled, and verified (e.g. via `zig build test`), the assistant must propose that a commit is ready.
- The assistant must present the proposed commit message (concise title and descriptive body adhering to project conventions) for user review.
- The user will review the proposed commit message, stage the desired changes themselves, and give explicit sign-off before any commit is executed.

## 4. Permitted Read-Only Git Operations

- The assistant is encouraged to run read-only Git inspection commands to verify repository state and changes:
  - `git status` (verify unstaged state and check for untracked files)
  - `git diff` (inspect working tree modifications)
  - `git log` (inspect recent commit conventions and history)
- The assistant must never modify Git configuration, hooks, or repository history (`git reset`, `git rebase`, `git push`, `git checkout .`, `git restore .` without user instruction).
