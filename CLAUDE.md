# Deckhand

A native SwiftUI macOS menu bar and hub app for iOS Simulators, Android Emulators and physical devices. `DeckhandCore/` is a Swift package (logic and tests); `Deckhand/` is the app target (views, AppKit glue). The Xcode project uses a folder-synced group, so new files are picked up automatically.

## Commits

Release notes and the version history are built from commit messages, so every commit is a semantic (Conventional Commits) one:

```
<type>: <what changed, lower case, no full stop>

<why, and what it replaces; wrap at about 100 columns>

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
```

| type | use for | in the release notes |
|---|---|---|
| `feat` | something a user can do or see that they could not before | Added |
| `fix` | a bug a user could hit, and a regression | Fixed |
| `perf` | the same behaviour, faster or lighter | Changed |
| `refactor` | structure only, no behaviour change | left out |
| `docs` | README, guide, site, CHANGELOG only | left out |
| `test` | tests only | left out |
| `ci` | workflows and `.github/scripts` | left out |
| `build`, `chore` | project files, dependencies, version bumps (`chore(release)` and `chore(cask)` come from the release workflow) | left out |

- One subject line per change, written for the person reading the release notes: say what the user gets (`feat: network capture belongs to each device`), not which file changed.
- A breaking change gets `!` after the type (`feat!:`) and says what to do in the body.
- Keep commits atomic: one change each, with its own docs and tests. Do not mix a fix with an unrelated feature.
- Use `/usr/bin/git` (a hook rewrites plain `git` in worktree sessions).
- Pushes to GitHub over SSH often time out: retry (`perl -e 'alarm 40; exec @ARGV' /usr/bin/git push`) and compare `HEAD` with `origin/main`. The release workflow pushes `chore(release)` and `chore(cask)` commits to `main`, so `git pull --rebase` before pushing.

## Docs go with the feature

A user-visible change also updates, in the same commit: `CHANGELOG.md` (under `## [Unreleased]`, `### Added`, `### Changed` or `### Fixed`, one line each, written for users), `docs/guide.md`, and `README.md` or `site/` when the feature list changes. The release uses the CHANGELOG section of the new version when there is one, and GitHub's generated notes otherwise.

## Build and test

- Core tests: `swift test --package-path DeckhandCore` (wrap in `perl -e 'alarm 900; exec @ARGV' …`; there is no `timeout` on macOS). A few real-network proxy tests are flaky on their own (about 1 run in 10).
- App: `xcodebuild -project Deckhand.xcodeproj -scheme Deckhand -configuration Debug -derivedDataPath /private/tmp/dhderived build`. Relaunch with `pkill -TERM -f "^/private/tmp/dhderived/Build/Products/Debug/Deckhand.app/Contents/MacOS/Deckhand"; sleep 2; open /private/tmp/dhderived/Build/Products/Debug/Deckhand.app`.
- Never start a second Deckhand while the user's own is running: it reaps the other instance's helpers. Do not open `deckhand://` links, which launch `/Applications/Deckhand.app`.
- Keep long SwiftUI modifier chains split into steps (`HubView.content`): one long chain made the release compiler fail with "unable to type-check this expression in reasonable time" on CI, though it built locally.
- The Android helper (`DeckhandHelper/`) is built by the release workflow. `Deckhand/DeckhandHelper.apk` is git-ignored: rebuild it with `DeckhandHelper/build.sh` after changing the helper, and bump `versionCode` there and `DeviceProxySetup.helperVersion` together.
