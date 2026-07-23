# zprompt

A fast, minimal zsh prompt written in Zig. Replaces [Starship](https://starship.rs/) with a single compiled binary — no config file, no runtime dependencies.

## Why

- **197 KB** binary vs Starship's 8.2 MB (42x smaller)
- **29 ms** average render vs Starship's 41 ms (1.4x faster)
- Zero dependencies beyond system `git`
- All configuration is compiled in — modify the source and rebuild
- 4 source files, easy to understand and modify with an LLM

## What it shows

```
[blank line]
HH:MM:SS ~/path/to/repo_root/subdir main ●●▴ +12 -3 py3.11(@venv) js22.1.0
❯

# Detached HEAD with tags
HH:MM:SS ~/path/to/repo a3f7b2c 🏷️(9) shortest-tag ● js22.1.0
❯
```

| Segment | Source | Description |
|---|---|---|
| time | `std.time` | UTC+9 (JST), `HH:MM:SS` |
| directory | CWD | 3-color split in git repos: path (gray) / root (white) / inside (green). Worktree paths highlight both parent repo and worktree name in white |
| git_commit | `git status --porcelain=v2` | 7-char hash (detached HEAD only) + 🏷️ tag(s) if present |
| git_branch | `git status --porcelain=v2` | branch name (remote hidden when `origin/<branch>`) |
| git_status | `git status --porcelain=v2` | `⊘` conflicted, `✘` deleted, `»` renamed, `●` modified/untracked/staged, `▴▾` ahead/behind |
| git_state | `.git/` file checks | REBASING, MERGING, CHERRY-PICKING, REVERTING, BISECTING with progress |
| git_metrics | `git diff --numstat HEAD` | `+added` / `-deleted` lines (each shown independently when > 0) |
| aws_sso | `~/.aws/sso/cache/*.json` | Remaining SSO session time `🅰 HH:MM` |
| python | `python3 --version` | `py3.11.2(@virtualenv)` when python project detected |
| nodejs | `node --version` | `js22.1.0` when node project detected |
| cmd_duration | CLI arg | Shown when >= 30s: `⏱45s`, `⏱1m30s`, `⏱2h15m` |
| character | CLI arg | `❯` green on success, red on failure |

## Build

Requires [Zig](https://ziglang.org/) 0.16.0.

```sh
# Development build
zig build

# Release build (smallest binary)
zig build -Doptimize=ReleaseSmall

# Release build (fastest binary)
zig build -Doptimize=ReleaseFast
```

## Install

Add to `~/.zshrc`:

```zsh
# zprompt
_zprompt_preexec() { _zprompt_start=$EPOCHREALTIME }
_zprompt_precmd() {
    local ec=$?  dur=0
    if [[ -n $_zprompt_start ]]; then
        local elapsed=$(( ($EPOCHREALTIME - $_zprompt_start) * 1000 ))
        dur=${elapsed%.*}
        unset _zprompt_start
    fi
    PROMPT="$(/path/to/zprompt --exit-code=$ec --duration=$dur)"
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _zprompt_preexec
add-zsh-hook precmd _zprompt_precmd
```

Replace `/path/to/zprompt` with the actual binary path (e.g. `~/src/_mydev/prompt/zig-out/bin/zprompt`).

This is the synchronous setup: the shell blocks until zprompt returns, so in a large
repository where git collection is slow, the prompt is delayed. If that bothers you, use
the async setup below instead.

## Async prompt (optional)

In a slow repository the synchronous prompt makes you wait for git before anything appears.
The async setup shows an **instant** prompt (time + directory) immediately, computes the
**full** prompt in the background, and swaps it in when ready — without disturbing whatever
you are typing. It reuses the same binary; no plugin (`zsh-async` etc.) is required.

### CLI options used

| Option | Effect |
|---|---|
| `--deadline=<ms>` | Override the shared worker deadline. `--deadline=0` skips the workers entirely and emits only the synchronous segments (time, directory, character, duration) — the instant prompt. |
| `--no-deadline` | Wait for every worker and drop nothing — the full prompt, however long git takes. |

Without either flag the behavior is unchanged (800 ms shared deadline).

### Setup

Replace the synchronous block in `~/.zshrc` with this:

```zsh
zmodload zsh/system                       # for `sysread` (non-blocking read)
autoload -Uz add-zsh-hook

typeset -g _zp_bin=/path/to/zprompt        # <- set this to your binary path
typeset -g _zp_gen=0 _zp_fd=0 _zp_buf='' _zp_t0=''
typeset -gA _zp_fdgen                        # fd -> generation, for the staleness guard

_zp_preexec() { _zp_t0=$EPOCHREALTIME }

_zp_precmd() {
    local ec=$? ms dur=0
    if [[ -n $_zp_t0 ]]; then ms=$(( ($EPOCHREALTIME - $_zp_t0) * 1000 )); dur=${ms%.*}; _zp_t0=''; fi

    # 1) instant prompt: synchronous segments only, shown immediately
    PROMPT="$($_zp_bin --exit-code=$ec --duration=$dur --deadline=0)"

    # tear down a watcher left over from a previous prompt.
    # The fd close MUST be inside a brace group (see note below) — a bare
    # `exec {_zp_fd}<&- 2>/dev/null` permanently redirects the shell's stderr to /dev/null.
    if (( _zp_fd )); then zle -F $_zp_fd 2>/dev/null; { exec {_zp_fd}<&- } 2>/dev/null; unset "_zp_fdgen[$_zp_fd]"; fi
    _zp_fd=0; _zp_buf=''; (( _zp_gen++ ))

    # 2) full prompt computed in the background, streamed back over a pipe
    exec {_zp_fd}< <($_zp_bin --exit-code=$ec --duration=$dur --no-deadline)
    _zp_fdgen[$_zp_fd]=$_zp_gen
    zle -F $_zp_fd _zp_cb
}

_zp_cb() {
    # zle calls this with $1 = fd whenever it is readable. Drain without blocking;
    # a failing sysread means EOF, i.e. the background prompt has finished.
    local fd=$1 chunk
    if sysread -i $fd chunk 2>/dev/null; then _zp_buf+=$chunk; return; fi
    local gen=${_zp_fdgen[$fd]}
    zle -F $fd 2>/dev/null; { exec {fd}<&- } 2>/dev/null; unset "_zp_fdgen[$fd]"; (( fd == _zp_fd )) && _zp_fd=0
    # apply only if no newer prompt started meanwhile (don't clobber a fresh prompt)
    if [[ $gen == $_zp_gen && -n $_zp_buf ]]; then PROMPT=$_zp_buf; zle reset-prompt; fi
    _zp_buf=''
}

add-zsh-hook preexec _zp_preexec
add-zsh-hook precmd  _zp_precmd
```

### How it works, and the one thing you must not remove

`precmd` paints the instant prompt, then starts a background `--no-deadline` run and watches
its pipe with `zle -F`. When the full prompt arrives, the callback swaps `PROMPT` and calls
`zle reset-prompt`, which redraws the prompt in place while preserving your edit buffer and
cursor. Updates only happen while you are at the prompt; once you press Enter, the line is
final.

The generation guard (`_zp_gen` plus the per-fd `_zp_fdgen` map) is not optional. If the
background run finishes *after* you have already submitted the command and moved to a new
prompt, applying its (stale) result would overwrite the new prompt with old data. Each
background pipe records the generation that started it; the callback applies the result only
when that generation still matches the current prompt.

Three zsh-specific details matter here. First — and this is the subtle one — the fd close
is written `{ exec {fd}<&- } 2>/dev/null`, **not** `exec {fd}<&- 2>/dev/null`. `exec` with a
redirection and no command applies that redirection to the shell *permanently*: a bare
`exec {fd}<&- 2>/dev/null` closes the fd **and** sends the interactive shell's stderr to
`/dev/null` forever. `fzf`, `skim` (`sk`), and other full-screen tools draw their UI to
stderr, so afterwards they render into the void and look like they hang before showing
anything (the process is fine; `lsof` shows the UI bytes going to `/dev/null`). Wrapping the
`exec` in a brace group scopes the `2>/dev/null` to the group and restores stderr afterwards,
leaving only the fd close. Second, `zle -F` takes a plain function *name* — you cannot bake an
argument into it (`"_zp_cb $gen"` would look for a function literally named that), which is why
the generation is passed through `_zp_fdgen` instead. Third, end-of-file on the pipe is
signalled by `sysread` returning non-zero, **not** by a `hup` state argument; waiting for a
`hup` that never arrives leaves the prompt un-updated and spins the callback. The callback
therefore treats a failing `sysread` as completion.

Requires zsh with the `zsh/system` module (standard) for `sysread`. If a full prompt can
exceed the read buffer (rare for a prompt line), the `sysread` accumulation already handles it
by appending across multiple readable events until EOF.

## Architecture

```
src/
├── main.zig      Entry point, arg parsing, async orchestration, output assembly
├── git.zig       Git info collection (.git/ reads + git subprocess)
├── modules.zig   Non-git modules (time, directory, python, node, aws, duration)
└── style.zig     ANSI color constants with zsh %{..%} wrapping
```

### Concurrency model

5 workers run in parallel via `io.async` (Zig 0.16's `std.Io`), sharing one 800 ms deadline:

| Worker | Work | Method |
|---|---|---|
| git_main | branch, status, ahead/behind, hash, tag | `git status --porcelain=v2 --branch` + `git tag --points-at HEAD` |
| git_extras | state detection, diff metrics | `.git/` file reads + `git diff --numstat` |
| python | version + virtualenv | marker file check + `python3 --version` |
| node | version | marker file check + `node --version` |
| aws_sso | session remaining time | `~/.aws/sso/cache/*.json` read + ISO 8601 parse |

Each worker is a function returning `?Result`; `io.async` returns a `Future` whose value main collects with `await`. The 800 ms budget is one absolute `Io.Timeout` passed to every subprocess (`std.process.run`'s `timeout`), so all git/version calls stop at the same wall-clock instant while the prompt still returns as soon as the work finishes. A subprocess that overruns is killed and its result dropped to `null`. `--no-deadline` passes `.none` (wait for everything); `--deadline=0` skips the workers entirely.

Synchronous (no worker): time, directory, character, cmd_duration.

### Error handling

Every module returns `null` on failure. The output assembly skips null segments. The prompt always renders — at minimum you get the time, directory, and character.

## Customization

All configuration is compiled into the binary. To customize:

1. Edit the source files (colors in `style.zig`, formats in `git.zig`/`modules.zig`)
2. Rebuild with `zig build -Doptimize=ReleaseSmall`

## Benchmarks

Measured with `hyperfine --warmup 10 --runs 100` in a git repository on macOS arm64:

| | zprompt | Starship 1.26.0 |
|---|---|---|
| Binary size | 197 KB | 8.2 MB |
| Mean | 29.4 ms | 41.1 ms |
| Min | 23.4 ms | 27.0 ms |
| Std dev | ±4.9 ms | ±5.3 ms |
