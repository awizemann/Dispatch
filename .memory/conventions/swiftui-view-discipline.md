---
title: SwiftUI View Discipline
type: note
permalink: dispatch/conventions/swiftui-view-discipline
tags: [swiftui, performance, standard]
created: 2026-07-05
updated: 2026-07-21
---

From kickoff standard §6. Dispatch consequences: the Messages inbox is the heavy subtree — its search must not couple to the detail it renders, and switching projects must NOT .id()-reset it; volatile draft/hover state lives outside the list; scroll views need bounded heights inside the rail + center layout.

## Observations
- [convention] Never .id(x)-reset a heavy subtree (full synchronous teardown+rebuild on main) — pass identity as input, reset child @State via .onChange(of:), key loads with .task(id:) #identity
- [convention] Resolve a detail view's selection by id from the UNFILTERED source — coupling detail to the search-filtered collection re-renders it every keystroke #selection
- [convention] Keep volatile @State (drafts, hovers) out of coordinators that also render heavy content — extract the interactive bit into its own view owning that state #state
- [gotcha] LazyVGrid/LazyVStack stays lazy only if its ScrollView has a BOUNDED height — an unbounded maxHeight .infinity chain realizes the whole page eagerly #lazy
- [convention] Debounce hot text fields ~250ms: bind to local @State, push to the model on a trailing timer #debounce


**Field-proven additions (P1 chat fixes):** (1) `proxy.scrollTo` issued inside an `onScrollGeometryChange` update pass is SILENTLY DROPPED — defer the scroll out of the pass (`Task { @MainActor … }`). (2) A stick-to-bottom flag computed from "near bottom?" self-defeats under streamed growth (content grows, offset stays → 'not near bottom' → follow disabled): drive re-anchoring from content-HEIGHT changes and flip the follow flag only on user movement AWAY from the bottom. (3) `NSTextView.undoManager` resolves to the WINDOW's shared undo manager — a multi-context composer needs its own private UndoManager and must drop the stack on programmatic replacement, or ⌘Z resurrects sent text across contexts.

- [gotcha] `.frame(width:height:)` default alignment is `.center` — a fixed-size child inside it gets CENTERED, silently re-basing any `.offset` math written for a top-leading origin by (container − child)/2. This shipped in DirectLineOverlay (0607f58): the 460pt panel unit was pushed right/down and on chat cards wider than ~1408pt landed entirely past the `.clipped()` edge — clicking the tab made the whole direct line vanish (fixed 2026-07-21). Any offset-positioned overlay must pin EVERY sizing frame's alignment explicitly #layout
- [gotcha] `.clipped()` is visual only — clipped-away content still hit-tests, so a slid-out-of-view panel silently eats clicks on whatever it invisibly covers; pair hide-by-clip with `.allowsHitTesting(isVisible)` #layout

- [gotcha] Hiding a shadowed view by parking it exactly on a `.clipped()` edge leaks its drop shadow through the clip (the blur extends past the view's frame) — translate it past the edge by a shadow-radius pad (DirectLineOverlay.shadowPad) so nothing bleeds #layout
