# Showrunner

A presenter console for macOS, for any talk that mixes slides, live demos, other apps and a talk track. It floats on your second screen and is hidden from screen sharing. You follow one run of show. Each step brings the right window forward and shows what to do and what to say. A clock tracks your pace against the plan.

It grew out of Handle's Autopilot, which was built for one customer demo. Showrunner reads any show file, finds Chrome tabs by URL instead of tab ID, and works without Handle. When Handle is running, Showrunner adds Handle's autoplaying demo flows.

## Run it

```
./build.sh                      # builds ~/Applications/Showrunner.app and links `sr` into ~/.local/bin
./build.sh --dist               # also writes dist/Showrunner.zip to give to someone else
sr new my-demo --from demo      # a show in ~/Showrunner, from an example
sr open ~/Showrunner/my-demo.show.md
```

Showrunner is a regular Mac app. It has a Dock icon, appears in ⌘-Tab and Spotlight, and has its own menu bar: File (New, Open, Open Recent, Edit Show File, Reveal in Finder, Reload), Show (Start / Next ⌘↩, items ⌘↓ ⌘↑, beats ⌘→ ⌘←, Pause ⌘P, Save Run ⌘S, Run Checks ⌘K), View and Help. You can also drop a show file on the Dock icon. With no show open, the window offers New, Open, the examples and your recent shows.

The View menu sets how the window behaves. Each setting is on by default and kept across launches:

- **Float on Top:** keeps the window above other apps.
- **Hide from Screen Sharing:** leaves the window out of screenshots and shares that honour it.
- **Don't Take Focus When Clicked:** clicking a button leaves Chrome or Keynote in front, so keyboard input still goes to the demo. Turn it off to use the menu shortcuts after clicking the window.
- **Menu Bar Icon:** the SR item in the menu bar, for opening shows while another app is in front.

The app bundle carries this guide (Help > Showrunner Guide), the examples (Help > Example Shows) and `sr.py`. Someone without the repo can run `Showrunner.app/Contents/Resources/sr.py`. The zip is unsigned, so on another Mac the first launch needs right-click > Open.

The window has two panes:

- **Presenter (left).** Shows the section and item, the orange DO cue, and what to say: paragraphs, or beats you step through. It also has buttons for this item's actions, and one big button. That button starts the show, plays or pauses a demo, or moves you to the next item.
- **Navigator (right).** Shows the clock and pace, then the slide image so you can match it to what's on screen. Below that are four tabs:
  - Run of show: the outline, with each section's budget, time spent and last rehearsal
  - Q&A: search every "if asked" note
  - Checks: preflight
  - Log: what each action did

Hotkeys work from any app:

- **⌃⌥↓ / ⌃⌥↑:** next or previous item.
- **⌃⌥→ / ⌃⌥←:** next or previous beat, or demo step.
- **⌥Space:** pauses the demo, or the clock.

**A− / A+** set the text size.

## Show files

You can write a show in Markdown (`*.show.md`) by hand, or in JSON (`*.show.json`) when another tool generates it. Showrunner reloads the file when it changes, so you can edit it mid-rehearsal.

```
title: Product demo

# Feature one (5m)                         section, with a time budget

## [slide 2] Why it exists (1m)            item: [slide N] [demo] [talk] [app] [video] [break]
@image slides/slide-02.png                 thumbnail to match what's on screen
> Slide 2.                                 DO: what to do

What to say, as paragraphs.

## [demo] Admin setup
@chrome admin\.example\.com | https://admin.example.com
@fallback video ~/Movies/feature-one.mp4
- A beat: one thing to point at.           beats; ⌃⌥→ steps through them
? If asked: the answer you keep ready.     a note on the beat above

# Q&A
## When is it GA?
December.
```

Actions run when you arrive on an item, in the order listed:

| Directive | What it does |
|---|---|
| `@chrome <regex> \| <url>` | Brings forward the first Chrome tab whose URL or title matches. If none matches, it opens the URL. It uses Handle when Handle is running, and AppleScript otherwise. |
| `@handle N` | Brings forward the tab pinned to Handle autopilot flow N. The presenter then shows that flow's steps and lines, with Play / Pause. |
| `@app Name \| file` | Opens or brings forward an app, optionally with a file (VS Code on the right file). |
| `@open path-or-url` | Opens a file or URL with its default app. |
| `@keynote N` | Starts Keynote at slide N, or jumps there if the show is already running. |
| `@powerpoint N` | Best effort. PowerPoint shows on the screen that holds the deck window and can't jump inside a running show, so prefer moving through PowerPoint by hand. |
| `@video path` | Plays a video full screen in QuickTime. |
| `@shell cmd` (+ `@cwd dir`) | Never runs on arrival. It becomes a button that runs the command in a visible Terminal window. |
| `@wait seconds` | Pauses between actions. |
| `@fallback <action>` | Goes behind the "Use fallback" button, for when the live system fails. |
| `@owner Name` · `@min 2` · `@noauto` | Sets the presenter for a hand-off, sets the planned minutes, or tells the item not to run its actions on arrival. |

JSON uses the same model: `{title, preflight:[...], qa:[{q,a}], sections:[{title, minutes, owner, items:[{kind, title, cue, say, note, lines:[{say,note}], image, slide, minutes, owner, go:[actions], fallback:[actions]}]}]}`, where an action is an object such as `{"chrome": "admin", "open": "https://..."}`.

## Your shows and past runs

The **Shows** tab lists every show in `~/Showrunner` (any folder inside it) and every show you opened recently. Each row shows the item count, planned time and saved runs, with Open and Share… buttons. The open show also lists its last ten runs: press **Compare** on one and the outline shows that run's section times beside each budget. With no show open, the window lists the same shows.

## Share a show so someone else can run it

**Share…** (File > Share Show…, ⌘⇧S, or the button in the Shows tab) packs the show into one `.showrunner` file in `~/Showrunner/Shared/`. The file holds:

- the show file, with its paths rewritten to point inside the pack
- every local file the show refers to: slide images, videos, fallback recordings, files for `@open` and `@app`, and anything listed under `attach:`
- the show's saved runs

Then it offers AirDrop, Mail, Messages and the other share options. The recipient needs Showrunner installed (the zip from the Releases page; right-click > Open the first time). They double-click the file, and Showrunner unpacks it into `~/Showrunner/<name>/` and opens it.

On their Mac:

- `@chrome` items find the tab by address, or open the URL. They need their own access to whatever the URL points at.
- Items that use Handle's autoplay show the talk track as beats instead, because Handle isn't there. The cue may still say to press Play; follow the beats.
- `@shell` and `@app` items depend on the same app or folder existing on their side.

`attach:` (Markdown front matter, repeatable) or `"attach": [...]` (JSON) keeps files with the show, such as the deck. The 📎 menu in the window opens them.

```
sr pack show.show.md            # writes ~/Showrunner/Shared/<title>.showrunner
sr unpack file.showrunner       # unpacks into ~/Showrunner and prints the show path
sr from-autopilot run.json --flows flows.json --fallback recordings/ --attach deck.pptx
                                # an Autopilot run of show that works without Handle: URLs, beats, recordings
```

## Preflight

`preflight` in a JSON show lists what must be ready. Checks run from the Checks tab, or with `sr check`.

- **Chrome tab:** `{"chrome": "regex", "open": "url"}` checks that a matching tab is open. The Fix button opens it.
- **App:** `{"app": "Microsoft Teams"}` checks that the app is running.
- **File:** `{"file": "path"}` checks that the file exists.
- **URL:** `{"url": "https://..."}` checks that the address answers.
- **Displays:** `{"displays": 2}` checks how many screens are connected.
- **Handle:** `{"handle": true}` checks that Handle's bridge is reachable.
- **Manual:** `{"label": "Do not disturb on"}` is a check you tick yourself.

## Rehearse

Press **Start the show**, run through it and press **Save run**. Each run is appended to `<show>.rehearsals.json` next to the show, recording the planned and actual time per item. The outline then shows each section's time from the last run beside its budget.

## Drive it from elsewhere

Showrunner answers on `127.0.0.1:4977`. Use it from a clicker app, a Stream Deck, a phone shortcut over your own network relay, or Claude:

```
sr state | sr next | sr prev | sr go 5 | sr primary | sr toggle | sr beat | sr start | sr pause | sr reload | sr save
curl 127.0.0.1:4977/next
```

## Build a show from what you have

```
sr import deck.pptx --pdf deck.pdf        # one item per visible slide, speaker notes as the talk track, slide images
sr from-autopilot ~/.config/autopilot/run.json   # convert a Handle Autopilot run of show
sr check show.md                          # list items and actions, flag missing images, run preflight
```

## Use cases

| Situation | What to use |
|---|---|
| Customer demo: deck, then live instance, then back to the deck | `[slide]` items with images; `[demo]` items with `@chrome` or `@handle`; `@fallback video` for when the instance is down; a Q&A section for the hard questions |
| Recorded or autoplaying demo | `@handle N` flows that click through the product while you talk; the presenter shows each step's line |
| Conference talk in Keynote | `@keynote N` per item, beats per slide, the pace indicator, `[break]` for pauses |
| Talk from a PowerPoint deck | `sr import deck.pptx --pdf deck.pdf`; move through the slides by hand; Showrunner shows the notes and the slide image |
| Developer demo | `@app Visual Studio Code \| file`, then `@shell npm run build` as a button, run in a visible Terminal |
| Interview case presentation | Section budgets for the time limit, beats instead of a script, Q&A for follow-ups |
| Workshop or training | `[break]` items for exercises, `@owner` per module, `@video` for recorded segments |
| Sales discovery call | A questions item as beats you tick off, a Q&A section for objections, a short `[demo]` |
| Quarterly or roadmap review with several presenters | `@owner` per section, so everyone sees whose turn it is |
| Rehearsal | Save run after each pass; compare each section's actual time against its budget |
| Before going live | Preflight checks: tabs open, apps running, instance reachable, displays connected |
| Hands-free | `sr next` from a script, a Stream Deck button or a phone shortcut |

## Limits

- The window asks macOS to leave it out of screen capture, and macOS's own screenshot tool does. It hasn't been confirmed whether Teams and Zoom leave it out. Test a share once before a live call.
- PowerPoint can't be driven reliably: the slideshow screen and jumping inside a running show both misbehave. Keynote can.
- Chrome without Handle needs a one-time Automation permission ("Showrunner wants to control Google Chrome").
- Hotkeys clash with Handle's Autopilot app while both run. Showrunner then says which hotkeys it couldn't take; use the buttons.
