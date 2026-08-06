# Mobile interface contract

Status: accepted on 2026-08-06

This document fixes the visual and interaction baseline for HN Continuity. The
canonical reference is [`design/style-guides/mobile-v1-overview.png`](design/style-guides/mobile-v1-overview.png).
It defines one coherent, light, mobile-first web interface for iPhone-sized
viewports.

The reference is directional, not a source of product data or route semantics.
Synthetic story titles, usernames, timestamps, counts, and prose in the image
are illustrative. If image copy conflicts with `SPEC.md`, `DECISIONS.md`, or
the route/data contracts, the written contract wins.

All other images currently under `docs/design/style-guides/` are rejected
explorations. They may be useful as history, but they are not implementation
references and must not be blended into this system.

## 1. Product surfaces

The persistent mobile navigation contains four labeled destinations:

1. **News**
2. **Inbox**
3. **Following**
4. **Settings**

`Thread` is a contextual destination reached from News, Inbox, Following, or a
direct URL. It uses a normal back link and does not become a fifth persistent
tab. `History` remains a real route but appears as the `Now / History` mode
switch inside News at narrow widths.

The canonical overview resolves these five principal views:

- News;
- Inbox with expanded direct-reply context;
- Following with branch and story activity;
- Thread with new-comment and watched-branch state;
- Settings.

## 2. Visual system

### 2.1 Palette

| Token | Value | Use |
| --- | --- | --- |
| `--color-bg` | `#ffffff` | page and primary surfaces |
| `--color-text` | `#15171a` | primary text and icons |
| `--color-accent` | `#f04422` | current state, new markers, primary links/actions |
| `--color-muted` | `#667085` | metadata and secondary labels |
| `--color-subtle` | `#f2f4f7` | segmented controls and grouped section surfaces |
| `--color-rule` | `#d9dde3` | dividers and ancestry lines |
| `--color-new-bg` | `#fff1ec` | watched/new branch emphasis |

Orange-red is the only brand accent. New/unread meaning always has a text or
shape cue in addition to color. Green may describe measured downward rank
movement, but it is data color rather than a second brand accent.

No beige, cream, sepia, paper texture, gradient, glass, decorative shadow, or
dark heritage treatment belongs in this design.

### 2.2 Typography

Use the system UI stack:

```css
font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
```

The working scale is:

| Role | Size / line height | Weight |
| --- | --- | --- |
| screen title | `24px / 29px` | `700` |
| story or context title | `16px / 21px` | `650` |
| body/comment | `15px / 21px` | `400` |
| navigation/control | `13px / 18px` | `500` |
| metadata | `12px / 16px` | `400` |

Use tabular numerals for ranks, scores, comment counts, and times. Do not use
condensed display fonts, oversized counters, or poster typography inside the
application.

### 2.3 Spacing and shape

- Base spacing unit: `4px`.
- Common steps: `4`, `8`, `12`, `16`, `20`, `24`, and `32px`.
- Page gutter: `16px` on narrow screens.
- Minimum interactive target: `44px` in either dimension.
- Dividers: `1px` using `--color-rule`.
- Small controls may use a restrained `6–8px` radius.
- Content lists are rows separated by rules, not collections of floating
  cards.

## 3. Shared shell

The application is a mobile web application, not a native iOS binary. Browser
chrome shown in the reference is environmental and is not rendered by the
application.

The application shell contains:

- the compact centered label `HN Continuity`;
- a page-specific heading below it;
- the four-item labeled bottom navigation on account-capable pages;
- a visible current-tab state using icon, label, and accent color;
- safe-area padding through `env(safe-area-inset-bottom)`;
- real links for navigation and real forms for mutations.

Icons are small inline SVGs with stable silhouettes. The visible text label is
never removed in favor of an icon-only destination.

The bottom navigation may be sticky, but content remains reachable and
complete when sticky positioning or JavaScript is unavailable.

## 4. View contracts

### 4.1 News

- Render `News` as the page heading.
- Present `Now / History` as links or a GET form, not client-only tabs.
- State how many observed stories are newer than the previous visit.
- Render an explicit `NEW SINCE YOUR LAST VISIT` boundary.
- Each row contains rank movement, story title, domain, points, comments, and
  observed age.
- Put older stories below a labeled boundary.
- Do not wrap each story in a card.

### 4.2 Inbox

- Show a bounded unread count beside the heading.
- Provide `Unread / All` as server-backed views.
- Keep collapsed notifications compact.
- Expanded context names the exact tracked HN identity, shows the relevant
  original item, then the direct reply, story, and ancestor context.
- Rendering does not mark a notification read; the explicit open/read
  operation does.
- `View branch` opens the deterministic focused thread context.

### 4.3 Following

- Provide `Branches / Stories` as server-backed views.
- Group watched branches separately from watched stories.
- Show new activity counts, latest meaningful event age, and causal watch
  scope.
- Keep `Mark seen`, `Mute`, and `Unfollow` explicit, compact forms.
- Use the pale accent background only for genuinely new or selected activity.

### 4.4 Thread

- Lead with a back link, story title, score, and comment count.
- Render stable chronological siblings using thin ancestry lines.
- Mark comments newer than the previous rendered snapshot with both a slim
  accent rail and the word `NEW`.
- A followed branch may use `--color-new-bg`, but individual comments remain
  text rows rather than cards.
- Show the current follow state near the story header.
- The only reply/vote action is an external `Open on Hacker News to reply`
  link. There is no application composer or voting control.

### 4.5 Settings

Group rows under clear section labels:

- application account;
- tracked HN identities;
- passkeys;
- direct-reply, watched-branch, and watched-story preferences;
- private Atom feeds;
- muted domains;
- export and deletion.

Do not request an HN password or imply that tracking a public username proves
ownership. Email delivery is not shown before the deferred delivery milestone
is approved.

## 5. Responsive and accessibility rules

The first implementation target is iPhone-class Safari at `375px` and `390px`
CSS viewport widths. The layout must also remain usable from `320px` through
`430px` without horizontal page scrolling.

- Cap thread indentation so deep ancestry cannot collapse the reading column.
- Allow metadata to wrap beneath titles before shrinking text.
- Keep primary body text at least `15px` in the canonical mobile view.
- Respect dynamic type, `200%` browser zoom, reduced motion, and safe areas.
- Preserve visible focus, heading order, landmarks, form labels, and status
  announcements.
- Do not rely on hover, swipe-only gestures, or color alone.

Desktop is derived later from the same components and tokens; it must not
introduce a separate visual language. Dark mode is not defined by this
decision and must not be inferred from the rejected exploratory boards.

## 6. Rendering and enhancement rules

- The first response contains the useful list or thread state as complete
  server-rendered HTML.
- The same view model drives full pages and optional HTMX fragments.
- `Now / History`, `Unread / All`, `Branches / Stories`, follow, mute, mark
  seen, export, and deletion work without application JavaScript.
- App SSE may update a count or show a small refresh banner; it does not mutate
  an open comment tree in place.
- There is no client-side state store, hydration layer, or frontend build
  system.

## 7. Visual acceptance

Before a view is considered complete:

1. compare its structure and hierarchy with the canonical overview;
2. exercise `375px` and `390px` iPhone-class viewports in real Safari/WebKit;
3. exercise the same journey with JavaScript disabled;
4. verify no horizontal page scroll, clipped control, hidden focus, or content
   covered by the bottom navigation;
5. test long titles, long usernames, deep branches, empty states, stale data,
   deleted items, and large counts;
6. confirm every state-changing control remains a bounded native form with a
   `303` result.

Pixel matching the generated story copy or simulated Safari chrome is not an
acceptance criterion. Stable hierarchy, tokens, density, semantics, and
interaction behavior are.
