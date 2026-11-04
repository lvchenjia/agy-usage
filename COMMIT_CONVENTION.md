# Git Commit Convention Specification

This project follows the **[Conventional Commits (v1.0.0)](https://www.conventionalcommits.org/)** specification with concrete scope definitions and length constraints tailored for `agy-usage`.

---

## 1. Structure

Every commit message consists of a **Header**, an optional **Body**, and an optional **Footer**:

```
<type>(<scope>): <subject>

[optional body: explanation of motivation, root cause, and key technical changes]

[optional footer: issue references or breaking change warnings]
```

---

## 2. Type Guidelines

| Type | Description | When to use |
| :--- | :--- | :--- |
| **`feat`** | A new feature | Introducing new capabilities to users (e.g. account profile header, remote control switch) |
| **`fix`** | A bug fix | Fixing an incorrect behavior, crash, or calculation error (e.g. token speed calculation bug) |
| **`perf`** | Performance improvement | Speeding up token scanning, reducing UI redraws, or optimizing SQLite queries |
| **`refactor`** | Code refactoring | Code restructuring without fixing a bug or adding a feature |
| **`docs`** | Documentation | Updates to `README.md`, `README.zh-CN.md`, code comments, or architectural docs |
| **`style`** | Code style / formatting | Whitespace, indentation, code formatting that does not change logic |
| **`test`** | Tests | Adding or adjusting automated tests, mocks, or validation scripts |
| **`build`** | Build system / scripts | Changes to `build.sh`, `Info.plist`, compiler flags, or bundle assembly |
| **`chore`** | Maintenance | Tooling, `.gitignore`, dependency updates, or internal scripts |

---

## 3. Scopes for `agy-usage`

Using scopes is highly recommended to pinpoint which subsystem was modified:

* **`menubar`**: Status bar display item (`G96`, `G96 R`, fonts, baseline offset)
* **`menu`**: Menu dropdown components (`AccountMenuItemView`, `QuotaMenuItemView`, menu hierarchy)
* **`dashboard`**: Token Analytics Window (`TokenStatsWindowController`, cards, table, time-range filters)
* **`remote`**: Remote control daemon integration (`RemoteControlService`, start/stop CLI commands, debouncing)
* **`quota`**: Connect-RPC Language Server discovery, polling, and quota parsing (`DaemonClient`)
* **`tokens`**: SQLite session scanning, WAL mode handling, token & duration calculations (`TokenStatsManager`)
* **`build`**: Build scripts (`build.sh`), packaging, and installation paths

---

## 4. Subject Constraints (Header)

The subject is a concise summary of the change:

1. **Character Limit**: **Strictly ≤ 72 characters** (recommended **≤ 50 characters**).
2. **Imperative Mood**: Use the imperative, present tense:
   * ✅ `add account profile card to dropdown menu`
   * ❌ `added account profile card`
   * ❌ `adds account profile card`
3. **Punctuation**: Do **not** end with a period (`.`) or trailing whitespace.
4. **Casing**: Lowercase preferred.

---

## 5. Body Constraints

When a commit involves non-trivial logic, multiple files, or a bug fix, a body should be provided:

1. **Line Length Limit**: Wrap lines at **72 to 80 characters** to ensure clean formatting in terminal pagers and GitHub.
2. **Content Focus**:
   * **Why**: Explain the problem, user request, or root cause.
   * **What / How**: Outline the key architectural changes or edge cases addressed.
   * **Avoid**: Do not merely recite the diff ("modified line 15").

### Example Body:
```
Fix token generation speed reporting 800+ tok/s on multi-turn sessions.

Root Cause:
The session metadata cache was retaining only the first two steps' duration
while tokens from subsequent steps accumulated, causing token count to be
divided by an artificially small time delta. Active WAL databases also threw
SQLITE_CANTOPEN (14) during concurrent writes.

Resolution:
- Switched SQLite connection to URI mode mode=ro&immutable=1.
- Implemented 1-to-1 matching between duration and output tokens.
- Invalidated stale step caches on active session updates.
```

---

## 6. Examples (Good vs. Bad)

### ✅ Good:
* `feat(menu): add Google account profile card with tier badge`
* `fix(remote): prevent rapid clicking during daemon start/stop`
* `perf(tokens): use immutable SQLite URI to bypass WAL lock contention`
* `docs: add comprehensive Chinese README and commit guidelines`

### ❌ Bad:
* `fixed stuff` *(Too vague, no type, past tense)*
* `feat: added some new things to the status bar and fixed a few bugs in the remote control service and updated the readme` *(Exceeds 72 chars, mixes multiple types, non-imperative)*
* `update` *(Zero informative value)*
