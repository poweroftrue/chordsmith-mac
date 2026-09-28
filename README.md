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
- Type your chords on a laptop keyboard as shorthands while the Forge is away.

## Grow: Add Chords In Batches

The **Grow** tab ranks the words that cost you the most time typed letter by
letter over the last 7, 30 or 90 days, and gives each one a chord. Every first
choice is conflict-free against your library and against the words ranked
above it, so you can select the top 5, 10 or 25, stage them in one go, check
them in **Staged**, and commit them to the M4G as a single batch.

- Inflections of words you already chord (`running` from `run`) are shown as
  endings and get the base chord plus one marker key.
- Likely typos of chorded words (`hte`, `waht`), half-typed fragments finished
  by shell completion, and Arabic words are kept out of the list.
- Skip a word to stop it being suggested; restore it from the Skipped section.

## Practice

The **Practice** tab turns the recorder's data into drills:

- **You have a chord but typed it**: words with a chord that you still type
  letter by letter, with how often you chorded them instead.
- **New chords to adopt**: chords added from Chordsmith in the last 30 days,
  until you mark them learned.
- **Typos a chord would have prevented**.
- **Drills** of five words at a time: chord each word into the field, see your
  time and chords per minute, repeat with the chord hidden, then move on.

## Live Coaching

While you type anywhere, Chordsmith can show a small hint under the menu bar
at the moment a chord would have been faster:

- a word you already have a chord for (`exit → i+x`);
- a typo of a chorded word (`hte → the`);
- a word you have typed by hand three times today that Grow has a chord for,
  with **Add chord** to write it to the M4G straight away.

Hints never take focus and fade on their own. They are rate-limited (20
seconds apart, 10 minutes per word, a per-hour cap you choose) and can be
limited to typing on the Master Forge. Configure them in Settings › Live
coaching.

When no Master Forge is connected (both halves unplugged), chord hints pause
automatically; only laptop shorthand hints remain. Words typed then are recorded as "keyboard, M4G not connected":
they count toward word totals and typing speed, but not against your chord
rate, the forgotten-chords list or Grow's ranking, because no chord was
possible.

The menu bar shows today's chord rate next to the icon; its tooltip adds the
goal (90% of your 50 most-used chorded words) and today's M4G letter speed.

## Laptop Shorthand

A MacBook keyboard can't press four or five letter keys at once reliably
(built-in keyboards ghost at three), and holding keys back to detect chords
makes every keystroke lag. So on the laptop, a chord becomes a shorthand:
**type the chord's letters in any order, then Space**, and they are replaced by
the chord's output. `abt␣` becomes `about ␣` if a+b+t is your chord for about.

- **Your chords, converted.** Chords made of letters keep their keys. A chord
  with DUP becomes its letters with one doubled (`thh` for t+h+DUP). Chords
  that use Forge-only keys (the ambidextrous throws, modifiers) get short new
  letters (`elv` for eleven). Chords whose keys spell the word itself (i+t for
  it) need nothing: just type the word.
- **Real words are never replaced.** `bat` stays `bat` even though a+b+t is a
  chord. The check uses Apple's built-in English vocabulary, every word you
  have typed at least three times (jargon, names, commands), and common shell
  and chat tokens (`ls`, `cd`, `pr`, `com`). Only a token typed right after a
  space, a new line or a cursor move counts, so `gmail.com` is safe.
- **Backspace right after puts your letters back.** Undo the same letters twice
  and they stay as typed from then on (see Laptop › Off & blocked).
- **Punctuation works too:** `bc,` becomes `because,`. Capitals carry over:
  `Abt` becomes `About`, `ABT` becomes `ABOUT`.
- **Nothing is delayed.** Keys pass straight through; only the Space after a
  shorthand is consumed. Shortcuts, key repeat, arrows and games are untouched.
  The hook runs on its own thread, so a busy app never slows your keyboard.
- **It gets out of the way:** paused while the Master Forge is connected (you
  can change that), in password fields, with non-Latin input sources (Arabic),
  and in any app you pause from the Laptop tab.

The Laptop tab lists every shorthand, most-typed words first, with the
letters to type, keystrokes saved and a way to change the letters or turn one
off. With no Forge connected, live coaching points out words you typed in full
that have a shorthand. Shorthand words appear as their own series in Stats.

Shorthand needs Accessibility access (System Settings › Privacy & Security ›
Accessibility) to replace text. It replaces the old software chording engine,
which held every key back and replayed it.

## Phrase Chords

Grow › Phrases lists two- and three-word phrases you write at least four times
in the window, each with a chord made from the first letter of every word plus
space (`can you` → `c + y + space`), conflict-free across the batch.

## Letter-By-Letter Speed

Practice shows today's letter-by-letter speed on the M4G next to other
keyboards, a history of speed drills, and your slowest letter pairs. A speed
drill is about fourteen of your own words, weighted toward those slow pairs;
type them on the M4G without chords to get WPM, accuracy and per-pair timing.

## Stats

The **Stats** tab puts every metric in one place for the last 7 days, 30
days, 90 days or 12 months, following Apple's chart guidelines: each chart
leads with a one-line summary, hovering anywhere over a chart shows that
day's values, rates use a fixed 0–100% scale, and every chart describes itself
to VoiceOver and Audio Graphs.

- Words per day, split into chorded, typed on the M4G and typed on other
  keyboards, with a table view.
- Chord rate against library coverage: the gap is chords you have but didn't use.
- Letter-by-letter speed in WPM on the M4G versus other keyboards.
- Chords per day or month, typo rate, time spent typing by hand, chords added,
  backspace correction rate, chord streak, most chorded words, most-typed words
  without a chord, and language mix.

Chord measures start on the first day the recorder could tell chords from
typing, so earlier days never read as zero percent chorded.

**Speed** groups words per minute by input method: other keyboards letter by
letter, and on the Master Forge chorded, letter by letter and blended. Each
word and its space is timed from the end of the previous word, with pauses
over three seconds left out (1 word = 5 characters).

**Accuracy** keeps typos and chord misfires apart because they have different
fixes. Typos are counted per 100 words typed by hand. A misfire is a chord
whose output you delete straight away (not a device modifier replacing its
own output), or chord-speed letters that match no chord and no word; the
most-misfired chords link to Advisor to find a more reliable chord.

## Advisor

The advisor is local and deterministic. It uses:

- the current M4G physical model;
- exact raw-input conflict checks;
- anchor-letter weighting for distinctive letters;
- English morphology such as plurals, `-ing`, `-ed`, `-tion`, `-ive`, and `un-`;
- existing family chords, such as extending `necessary -> n+e+c` into `unnecessary -> n+e+c+u`;
- starred chords as local feedback for preferred chord style.

The advisor also learns from your whole library: how often you include the
first letter, how many keys you give a word of each length, and which key you
add for endings (from pairs like `deploy` / `deployment`). A word built on a
chorded stem gets your stem chord plus your ending key. Two-key chords are kept
for words you write often, and chords one key away from an unrelated chord are
penalised because a partial press would type the other word. Two-word phrases
start from each word's first letter.

It learns mostly from the chords you use: each chord counts by how often you
write its word, so never-used chords barely shape the suggestions. It also
learns how your fingers move together in those chords (thumb pairs are easy;
neighbouring fingers moving in different directions are hard; three keys on one
hand you never press together count as hard), since a chord can
break the letter rules (`,+a+l+n` for national) and still sit well under your
hands. When a word's natural letters are taken, it offers them with one of the
marker symbols you use (`/+p+t+c`), about as often as you use markers yourself.

**Reclaiming keys.** When the best keys for a new word belong to a chord you
barely write (about once a month or less over every day the recorder ran, and
added over 30 days ago), the advisor offers them second in the list, with a
note: "Takes these keys from “god” (never written in 46 days); it moves to
.+g+d". Choosing it moves the old chord to its new keys and adds the new word
in one commit; nothing is deleted. Usage over your whole history decides, not
recency, so words you use for one project at a time keep their chords. Grow's
batches never move chords.

Hard validation always wins. A candidate is rejected if it conflicts with an existing raw input, uses unsupported actions, repeats a physical key, needs two or more directions of one switch, or presses both switches of a thumb lane. Suggestions never need a diagonal press (two neighbouring directions of one switch); a chord you enter yourself may use one.

## Window And Shortcuts

Click the menu bar icon to open the Chordsmith window, and click it again to
hide it. Right-click the icon for quick actions: add a chord, turn laptop
shorthand on or off or pause it in the current app, Settings, Quit. While the
window is open Chordsmith appears in the Dock and the app switcher; `Cmd+W`
closes it and returns it to the menu bar.

Default shortcuts:

- `Cmd+Shift+Space`: open or hide the window.
- `Cmd+Option+Space`: open the window on Advisor.
- `Cmd+Shift+A` or double-tap `Control`: open Quick Chords.
- `Cmd+Option+Shift+Space`: open the window.
- `Cmd+1` … `Cmd+8`: switch tabs.

Inside Quick Chords:

- type a word to find its chord; with an empty search, the words you type by
  hand most are listed so you can add one with `Return`.
- `Return`: open the selected chord, or save while adding.
- `Cmd+N`: new chord. `Cmd+F`: back to search. `Cmd+C`: copy the output.
- arrow keys: move through results or suggested keys.
- `Tab`: next field while adding.
- `Esc`: step back (stop recording, back to search, clear the search, close).

## Device Workflow

The normal workflow is:

1. Stage a chord add, edit, or delete.
2. Commit.

Commit applies the local database change and writes only that staged device mutation to the M4G. It does not run a full device reconciliation as part of the normal flow. If the device write fails, the local change stays committed and the failed device mutation is queued for retry.

## Install And Start At Login

Requirements:

- macOS 13 or newer
- Xcode command line tools or Xcode
- Swift 6.2 toolchain

Build a signed local app bundle, install it in `~/Applications`, and launch it:

```sh
./scripts/install_app.sh
```

On its first bundled launch, Chordsmith registers the main app with macOS 13+
Service Management. It then runs as an efficient menu-bar app at each login.
You can disable it or open macOS Login Items from Chordsmith Settings.

On first launch, grant **Input Monitoring** when macOS asks. If it is not yet
enabled, open Chordsmith's **Usage** tab and choose **Input Monitoring…**, then
enable Chordsmith in **System Settings › Privacy & Security › Input Monitoring**.
The recorder retries automatically when you return to Chordsmith. It remains
paused—and saves no words—until this permission is granted.

For a one-off development run, `swift run Chordsmith` still works, but launch at
login is intentionally unavailable outside an installed `.app` bundle.

Run tests:

```sh
swift test
```

## Data And Privacy

Chordsmith Mac stores local app data under macOS Application Support. The advisor runs locally and does not require an AI service or network access for chord generation.

The usage recorder requires macOS Input Monitoring permission. Laptop shorthand
additionally requires Accessibility permission; it keeps only the letters of the
word being typed in memory and stores daily counts of replacements, never text. A Master Forge is one logical device made from separately enumerated left (`m4g_s3`) and right (`m4gr_s3`) digitizer halves. Chordsmith recognizes both halves by their USB HID descriptor and correlates each half's key-down with the corresponding macOS keyboard event. Unmatched events are recorded as normal keyboard input; if physical attribution is unavailable, the recorder does not save the word. The Usage tab shows whether one or both Master Forge halves are available for physical attribution.

Two- and three-word phrases are stored the same way, as per-day counts only,
for phrase chords. Phrases seen once and not again within 14 days are deleted.

Words stay editable until the next word starts: backspacing into a word you
just finished (as CCOS suffix modifiers and quick typo fixes do) reopens it, and
Option+Backspace discards it, so only the final word is counted. Clicks, arrow
keys, Return and shortcuts end the word.

Word detection uses Apple's on-device Natural Language tokenizer and Unicode normalization for English and Arabic. Arabic tashkeel and tatweel are removed from aggregate keys so visually equivalent spellings count together. Only normalized word-level frequency, timing, language, and source aggregates are stored; raw keystrokes, sentences, and application names are not persisted. SQLite runs in WAL mode with normal synchronization to minimize write overhead for an always-on recorder.

## License

MIT. See [LICENSE](LICENSE).

The software is provided as is, without warranty of any kind.
