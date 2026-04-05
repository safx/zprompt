# zprompt

A fast, minimal zsh prompt written in Zig. Replaces [Starship](https://starship.rs/) with a single compiled binary — no config file, no runtime dependencies.

## Why

- **121 KB** binary vs Starship's 8.2 MB (68x smaller)
- **26 ms** average render vs Starship's 38 ms (1.4x faster)
- Zero dependencies beyond system `git`
- All configuration is compiled in — modify the source and rebuild
- 4 source files, easy to understand and modify with an LLM

## What it shows

```
[blank line]
HH:MM:SS ~/path/to/repo_root/subdir  a3f7b2c main(:origin/main) ●●▴ +12 -3 py3.11(@venv) js22.1.0
❯
```

| Segment | Source | Description |
|---|---|---|
| time | `std.time` | UTC+9 (JST), `HH:MM:SS` |
| directory | CWD | 3-color split in git repos: path (gray) / root (white) / inside (green) |
| git_commit | `git status --porcelain=v2` | 7-char hash + tag (if exact match) |
| git_branch | `git status --porcelain=v2` | branch name + tracking remote |
| git_status | `git status --porcelain=v2` | `⊘` conflicted, `✘` deleted, `»` renamed, `●` modified/untracked/staged, `▴▾` ahead/behind |
| git_state | `.git/` file checks | REBASING, MERGING, CHERRY-PICKING, REVERTING, BISECTING with progress |
| git_metrics | `git diff --numstat HEAD` | `+added` / `-deleted` lines (each shown independently when > 0) |
| aws_sso | `~/.aws/sso/cache/*.json` | Remaining SSO session time `🅰 HH:MM` |
| python | `python3 --version` | `py3.11.2(@virtualenv)` when python project detected |
| nodejs | `node --version` | `js22.1.0` when node project detected |
| cmd_duration | CLI arg | Shown when >= 30s: `⏱45s`, `⏱1m30s`, `⏱2h15m` |
| character | CLI arg | `❯` green on success, red on failure |

## Build

Requires [Zig](https://ziglang.org/) 0.15.2+.

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

## Architecture

```
src/
├── main.zig      Entry point, arg parsing, thread orchestration, output assembly
├── git.zig       Git info collection (.git/ reads + git subprocess)
├── modules.zig   Non-git modules (time, directory, python, node, aws, duration)
└── style.zig     ANSI color constants with zsh %{..%} wrapping
```

### Thread model

5 worker threads run in parallel with an 800 ms shared deadline:

| Thread | Work | Method |
|---|---|---|
| git_main | branch, status, ahead/behind, hash, tag | `git status --porcelain=v2 --branch` + `git describe` |
| git_extras | state detection, diff metrics | `.git/` file reads + `git diff --numstat` |
| python | version + virtualenv | marker file check + `python3 --version` |
| node | version | marker file check + `node --version` |
| aws_sso | session remaining time | `~/.aws/sso/cache/*.json` read + ISO 8601 parse |

Threads signal completion via `std.Thread.ResetEvent`. The main thread calls `timedWait` on each event with the remaining budget from the shared 800 ms deadline. Timed-out threads are detached — the process exits shortly after and the OS cleans up.

Synchronous (no thread): time, directory, character, cmd_duration.

### Error handling

Every module returns `null` on failure. The output assembly skips null segments. The prompt always renders — at minimum you get the time, directory, and character.

## Customization

All configuration is compiled into the binary. To customize:

1. Edit the source files (colors in `style.zig`, formats in `git.zig`/`modules.zig`)
2. Rebuild with `zig build -Doptimize=ReleaseSmall`

## Benchmarks

Measured with `hyperfine --warmup 5 --runs 50` in a git repository on macOS arm64:

| | zprompt | Starship 1.24.2 |
|---|---|---|
| Binary size | 121 KB | 8.2 MB |
| Mean | 26.2 ms | 37.7 ms |
| Min | 20.2 ms | 28.2 ms |
| Std dev | ±3.5 ms | ±9.6 ms |
