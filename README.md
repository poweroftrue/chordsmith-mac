# Chordsmith Mac

Chordsmith Mac is an unofficial macOS chord manager and deterministic advisor for CharaChorder.

It is built for fast local search, quick chord editing, M4G-aware suggestions, and safer device writes. It is a separate project and is not affiliated with, endorsed by, or maintained by CharaChorder.

## Screenshots

![Quick Chords search panel](docs/screenshots/quick-chords-search.png)

![Advisor suggestions panel](docs/screenshots/advisor-suggestions.png)

## What It Does

- Search an M4G chord library by output text, visible chord input, source, flags, macros, and action tokens.
- Add, edit, delete, and star chords from a compact floating quick panel.
- Suggest M4G chords using deterministic validation rather than AI.
- Reject physically impossible M4G inputs, including same-switch and same thumb-lane conflicts.
- Preserve raw device actions for non-plain and macro chords.
- Import and export CharaChorder chord JSON.
- Commit staged device changes directly to the connected M4G.
- Queue failed device writes for later retry instead of freezing the UI.

## Advisor

The advisor is local and deterministic. It uses:

- the current M4G physical model;
- exact raw-input conflict checks;
- anchor-letter weighting for distinctive letters;
- English morphology such as plurals, `-ing`, `-ed`, `-tion`, `-ive`, and `un-`;
- existing family chords, such as extending `necessary -> n+e+c` into `unnecessary -> n+e+c+u`;
- starred chords as local feedback for preferred chord style.

Hard validation always wins. A candidate is rejected if it conflicts with an existing raw input, uses unsupported actions, repeats a physical key, collides on a switch, or hits an impossible thumb lane.

## Quick Panel

Default shortcuts:

- `Cmd+Shift+Space`: open the main panel.
- `Cmd+Option+Space`: open quick advisor.
- `Cmd+Shift+A`: open Quick Chords.
- double-tap `Control`: open Quick Chords.

Inside Quick Chords:

- `Tab`: switch between search and add.
- `Return`: edit the selected chord or save the current quick add.
- `Cmd+C`: copy selected output.
- arrow keys: move through search results or advisor candidates.
- `Esc`: close.

## Device Workflow

The normal workflow is:

1. Stage a chord add, edit, or delete.
2. Commit.

Commit applies the local database change and writes only that staged device mutation to the M4G. It does not run a full device reconciliation as part of the normal flow. If the device write fails, the local change stays committed and the failed device mutation is queued for retry.

## Run Locally

Requirements:

- macOS 13 or newer
- Xcode command line tools or Xcode
- Swift 6.2 toolchain

Run from the repository root:

```sh
swift run Charaworder
```

Run tests:

```sh
swift test
```

## Data And Privacy

Chordsmith Mac stores local app data under macOS Application Support. The advisor runs locally and does not require an AI service or network access for chord generation.

## License

MIT. See [LICENSE](LICENSE).

The software is provided as is, without warranty of any kind.
