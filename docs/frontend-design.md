# Frontend design — 1.0.67

## Selected skill

The frontend workflow uses **UI/UX Pro Max v2.15.0**, pinned to upstream commit
`a38d04c3d5c298c851dbe5e6ee1965ee3de42cb5` (MIT).

- [Upstream release](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/releases/tag/v2.15.0)
- [Upstream skill directory](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/tree/v2.15.0/.claude/skills/ui-ux-pro-max)
- [Directory adoption snapshot](https://www.skills.sh/nextlevelbuilder/ui-ux-pro-max-skill/ui-ux-pro-max)

At selection on 2026-11-16 (Asia/Shanghai), the directory displayed about 453.3K
skill installs and 149.5K repository stars. These are adoption signals, not a
user satisfaction score. Anthropic frontend-design had higher overall adoption
but no equivalent Flutter-specific engineering guidance. This project keeps one
primary UI skill instead of importing React-only rules.

The full skill was installed separately with its data, scripts, references and
license. No executable skill dependency is added to the application.

## Product direction

DanbooruViewer is a content browsing tool. Keep images prominent, filtering
predictable, feedback local to the operation, and controls useful with a mouse,
keyboard or touch. Preserve the existing flat Material 3 light/dark palette,
teal accent and system fonts. Avoid extra remote font requests, decorative hero
sections and new state-management dependencies.

The skill's broad "image gallery" design-system query returned a generic
marketing layout. A narrower "file manager image browsing" query returned a
tool-oriented reference. Only the relevant low-decoration, content-priority and
fast-feedback guidance was used; the generated landing-page sections were not
adopted. Implementation guidance came from explicit Flutter and UX searches for
responsive constraints, lazy lists, asynchronous errors and compact-label
overflow. Flutter 3.38.9 remains the project runtime.

## Components and layout

| Component | Responsibility |
| --- | --- |
| `GallerySearchPanel` | Full-width labeled input, tag chips, rating filters, completion suggestions and reset |
| `GallerySectionHeader` | Result count, refresh and a visible multi-select entry |
| `GalleryRequestFeedback` | Recoverable request errors next to the retained gallery |
| `GalleryGrid` | Shared lazy image grid and optional pull-to-refresh |
| `GalleryEmptyState` | Scrollable loading, empty and failed states with an optional action |
| `PostThumbnailTile` | Pointer/keyboard interaction and selection semantics, including missing previews |

At widths below 1000 logical pixels, search stays above the gallery. Its height
is bounded and it can scroll independently when the keyboard or large system
text leaves little room. At 1000 pixels and wider, a 320-pixel sidebar holds
search and filters beside the gallery. The gallery uses its remaining width to
choose columns. Its header and error area share a bounded scrollable region so
short windows keep a visible image grid.

Long removable tags have a bounded single-line label. Activating the chip opens
a scrollable, selectable full value. This supports keyboard and touch users as
well as pointer tooltips. Native controls provide focus and press feedback;
actions have labels/tooltips and collection removal buttons have 48-pixel hit
areas. SafeArea protects bottom controls.

## Request behavior

- Submitting a query, choosing a tag or changing a rating creates a new request
  generation. Results from older generations are ignored.
- Pagination and refresh use the committed query snapshot. Editing an
  unsubmitted draft cannot change the query used for the visible gallery.
- A successful empty response displays an empty state. HTTP/network/time-out
  failures display a separate error state with a retry action.
- Refresh keeps the old posts visible while loading. A refresh failure retains
  those posts and pagination state; a successful empty refresh clears them.
- A failed next page keeps current posts and the previous page number. Automatic
  scroll loading pauses until the user retries, and retry requests the same page.
- Ctrl/Cmd+F focuses search. Escape first dismisses search suggestions/focus and
  then, on the next press, exits multi-select. Input drafts remain intact.
- Search inputs and their completion lists share a TextFieldTapRegion so mouse
  pointer-down does not remove a suggestion before pointer-up selects it.

## Verification scope

Widget regressions cover failed requests and recovery, request ordering, query
snapshot isolation, short-list refresh, keyboard behavior, no-preview media
interaction, collection filtering, mouse completion and long labels at 200%
text. Layout cases include 375×812, 320×300 and 1440×900, with both light and dark
themes. Existing completion, metadata migration and media lifecycle tests remain
part of the suite. These are automated checks, not an Android physical-device
latency measurement.
