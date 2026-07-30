// DesignSystemGallery.swift
// Dispatch DesignSystem — #Preview gallery exercising every token group.
// Visual verification only; ships no runtime code beyond previews.

import SwiftUI

// MARK: - Shared preview scaffolding

private struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Ink.tertiary)
            content
        }
    }
}

private struct SwatchCell: View {
    let name: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                .fill(color)
                .frame(width: 72, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                        .strokeBorder(Surface.hairline)
                )
            Text(name)
                .textStyle(TypeScale.monoTiny)
                .foregroundStyle(Ink.secondary)
        }
    }
}

// MARK: - Ink & Surfaces

#Preview("Ink + Surfaces") {
    VStack(alignment: .leading, spacing: 20) {
        GallerySection(title: "Ink") {
            HStack(spacing: 12) {
                SwatchCell(name: "primary", color: Ink.primary)
                SwatchCell(name: "secondary", color: Ink.secondary)
                SwatchCell(name: "tertiary", color: Ink.tertiary)
                SwatchCell(name: "faint", color: Ink.faint)
                SwatchCell(name: "mutedMono", color: Ink.mutedMono)
            }
        }
        GallerySection(title: "Surfaces") {
            HStack(spacing: 12) {
                SwatchCell(name: "white", color: Surface.white)
                SwatchCell(name: "panel", color: Surface.panel)
                SwatchCell(name: "chipNeutral", color: Surface.chipNeutral)
                SwatchCell(name: "codeBlock", color: Surface.codeBlock)
                SwatchCell(name: "controlBorder", color: Surface.controlBorder)
                SwatchCell(name: "scrim", color: Surface.scrim)
            }
            // v3 Obsidian recessed / translucent surfaces (composited over the
            // preview's white — the same way they render on white cards and the
            // light sheet). well/kanbanWell are the recessed-element fills;
            // cardTranslucent floats unselected cards; segmented is the recessed
            // segmented-control track; topBarWash is the top-bar frost.
            HStack(spacing: 12) {
                SwatchCell(name: "well", color: Surface.well)
                SwatchCell(name: "kanbanWell", color: Surface.kanbanWell)
                SwatchCell(name: "cardTranslucent", color: Surface.cardTranslucent)
                SwatchCell(name: "segmented", color: Surface.segmented)
                SwatchCell(name: "topBarWash", color: Surface.topBarWash)
            }
            Rectangle().fill(Surface.hairline).frame(height: 1)
            Rectangle().fill(Surface.hairlineStrong).frame(height: 1)
        }
    }
    .padding(24)
    .background(Surface.white)
}

// MARK: - Status + chips

#Preview("Status + Chips") {
    VStack(alignment: .leading, spacing: 20) {
        GallerySection(title: "Status chips (single StatusKind mapping)") {
            HStack(spacing: 8) {
                Chip("passed", style: .status(.success), mono: true)
                Chip("checking", style: .status(.warning), mono: true)
                Chip("failed", style: .status(.danger), mono: true)
                Chip("neutral", style: .neutral, mono: true)
            }
        }
        GallerySection(title: "Agent chips (colorIndex 0–4: indigo, slateBlue, amber, plum, rose)") {
            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    Chip(
                        "AG-0\(i + 1)",
                        style: .agent(AgentPalette.entry(forColorIndex: i), dot: true),
                        mono: true
                    )
                }
            }
        }
        GallerySection(title: "Over-limit bar color") {
            RoundedRectangle(cornerRadius: 2)
                .fill(Status.overLimit)
                .frame(width: Metrics.limitBarSize.width, height: Metrics.limitBarSize.height)
        }
    }
    .padding(24)
    .background(Surface.white)
}

// MARK: - Type scale

#Preview("Type scale") {
    VStack(alignment: .leading, spacing: 8) {
        Text("Doc H1 — 22 bold, tracking −0.3").textStyle(TypeScale.docH1)
        Text("Panel title — 16 bold, tracking −0.2").textStyle(TypeScale.panelTitle)
        Text("Chat name — 15 bold").textStyle(TypeScale.chatName)
        Text("Body chat — 14 regular").textStyle(TypeScale.bodyChat)
        Text("Body — 13.5 regular").textStyle(TypeScale.body)
        Text("Card title — 13 semibold").textStyle(TypeScale.cardTitle)
        Text("Control — 12.5 medium").textStyle(TypeScale.control)
        Text("Caption — 11.5 regular").textStyle(TypeScale.caption)
        Text("SECTION LABEL — 10 SEMIBOLD, TRACKING 0.6").textStyle(TypeScale.sectionLabel)
        Text("mono meta — 9.5 · src/Views/Chat.swift").textStyle(TypeScale.monoMeta)
        Text("mono tiny — 9 · 14:32:07").textStyle(TypeScale.monoTiny)
    }
    .foregroundStyle(Ink.primary)
    .padding(24)
    .background(Surface.white)
}

// MARK: - Depth, radii, shadows

#Preview("Depth model + Shadows") {
    @Previewable @State var theme = Theme()
    HStack(alignment: .top, spacing: 0) {
        // Outer chrome rail
        VStack(alignment: .leading) {
            Text("OUTER CHROME")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Ink.tertiary)
            Spacer()
        }
        .padding(12)
        .frame(width: 140)
        .frame(maxHeight: .infinity)
        .background(theme.outerChrome)

        // Canvas with floating white surfaces
        VStack(alignment: .leading, spacing: Metrics.surfacePadding) {
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Surface.white)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                        .strokeBorder(Surface.hairline)
                )
                .overlay(Text("work surface · radius 14 · cardShadow").textStyle(TypeScale.caption).foregroundStyle(Ink.secondary))
                .frame(height: 90)
                .cardShadow()

            HStack(spacing: Metrics.surfacePadding) {
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .fill(Surface.white)
                    .overlay(Text("popoverShadow").textStyle(TypeScale.caption).foregroundStyle(Ink.secondary))
                    .frame(width: 170, height: 80)
                    .popoverShadow()
                RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                    .fill(Surface.white)
                    .overlay(Text("modalShadow · radius 18").textStyle(TypeScale.caption).foregroundStyle(Ink.secondary))
                    .frame(width: 190, height: 80)
                    .modalShadow()
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .fill(Surface.white)
                    .overlay(Text("sheetShadow (up)").textStyle(TypeScale.caption).foregroundStyle(Ink.secondary))
                    .frame(width: 160, height: 80)
                    .sheetShadow()
            }
        }
        .padding(Metrics.surfacePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.canvas)
    }
    .frame(width: 760, height: 300)
}

// MARK: - Motion

#Preview("Motion") {
    @Previewable @State var toggled = false
    VStack(alignment: .leading, spacing: 16) {
        Button("Animate (state 120ms / rise 220ms / barFill 600ms)") {
            toggled.toggle()
        }
        HStack(spacing: 20) {
            Circle().fill(Status.successDot)
                .frame(width: Metrics.agentDot, height: Metrics.agentDot)
                .offset(x: toggled ? 60 : 0)
                .animation(Motion.state, value: toggled)
            Circle().fill(Status.warningDot)
                .frame(width: Metrics.agentDot, height: Metrics.agentDot)
                .offset(x: toggled ? 60 : 0)
                .animation(Motion.rise, value: toggled)
            RoundedRectangle(cornerRadius: 2)
                .fill(Status.overLimit)
                .frame(width: toggled ? 120 : Metrics.limitBarSize.width, height: Metrics.limitBarSize.height)
                .animation(Motion.barFill, value: toggled)
        }
        GallerySection(title: "Working dots blink (1.2s, reduce-motion aware)") {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in
                    Circle().fill(Ink.secondary).frame(width: 5, height: 5)
                }
            }
            .workingDotsBlink()
        }
    }
    .padding(24)
    .frame(width: 460)
    .background(Surface.white)
}

// MARK: - Theme (tunable accent · locked chrome/canvas)

/// v3 Obsidian: the accent stays a user-tunable 5-swatch picker;
/// outer-chrome and canvas are locked to spec, shown here as read-only displays.
#Preview("Theme (accent picker · locked chrome)") {
    @Previewable @State var theme = Theme()
    VStack(alignment: .leading, spacing: 16) {
        GallerySection(title: "System color (tunable)") {
            HStack(spacing: 8) {
                ForEach(Theme.accentOptions.indices, id: \.self) { i in
                    Button {
                        theme.accentIndex = i
                    } label: {
                        Circle()
                            .fill(Color(hex: Theme.accentOptions[i].base))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().strokeBorder(
                                    theme.accentIndex == i ? Ink.primary : .clear, lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Chip("accent chip", style: .accent(theme))
                RoundedRectangle(cornerRadius: Metrics.radiusControl)
                    .fill(theme.accentHover)
                    .frame(width: 60, height: 24)
                    .overlay(Text("hover").textStyle(TypeScale.monoTiny).foregroundStyle(.white))
            }
        }
        GallerySection(title: "Outer chrome · #181A21 (locked)") {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.outerChrome)
                .frame(width: 90, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Surface.controlBorder))
        }
        GallerySection(title: "Canvas · #E7E8EC (locked)") {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.canvas)
                .frame(width: 90, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Surface.controlBorder))
        }
        // Depth model: fixed chrome + canvas + a floating white surface.
        HStack(spacing: 0) {
            theme.outerChrome.frame(width: 90)
            ZStack {
                theme.canvas
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .fill(Surface.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                            .strokeBorder(Surface.hairline)
                    )
                    .padding(Metrics.surfacePadding)
                    .cardShadow()
            }
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusControl))
    }
    .padding(24)
    .frame(width: 520)
    .background(Surface.white)
    .environment(theme)
}

// MARK: - Chrome (dark rails / dark popovers — v3 Obsidian)

/// A swatch cell for the dark chrome group: label sits on the dark backdrop, so
/// text uses the on-dark ramp.
private struct DarkSwatchCell: View {
    let name: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                .fill(color)
                .frame(width: 72, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                        .strokeBorder(Chrome.cardBorder)
                )
            Text(name)
                .textStyle(TypeScale.monoTiny)
                .foregroundStyle(Chrome.textMuted)
        }
    }
}

/// A dark-variant status chip: foreground `color` on a 14%-alpha self-tint —
/// the Review-rail / MCP-popover treatment.
private struct ChromeStatusChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .textStyle(TypeScale.monoMeta)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Chrome.statusTint(color))
            )
    }
}

#Preview("Chrome (dark rails)") {
    VStack(alignment: .leading, spacing: 22) {
        // Text ramp
        VStack(alignment: .leading, spacing: 10) {
            Text("ON-DARK TEXT RAMP")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Chrome.sectionLabel)
            Text("textPrimary — wordmark, headers").foregroundStyle(Chrome.textPrimary)
            Text("text — card titles, menu items").foregroundStyle(Chrome.text)
            Text("textBody — note text").foregroundStyle(Chrome.textBody)
            Text("textMuted — secondary labels").foregroundStyle(Chrome.textMuted)
            Text("textMeta — mono metadata").foregroundStyle(Chrome.textMeta)
            Text("sectionLabel — ALL-CAPS labels").foregroundStyle(Chrome.sectionLabel)
            Text("textDisabled — empty states").foregroundStyle(Chrome.textDisabled)
        }
        .textStyle(TypeScale.control)

        // On-dark surfaces
        VStack(alignment: .leading, spacing: 10) {
            Text("ON-DARK SURFACES (white-alpha over the backdrop)")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Chrome.sectionLabel)
            HStack(spacing: 12) {
                DarkSwatchCell(name: "card", color: Chrome.card)
                DarkSwatchCell(name: "selected", color: Chrome.selected)
                DarkSwatchCell(name: "hover", color: Chrome.hover)
                DarkSwatchCell(name: "railTab", color: Chrome.railTabActive)
                DarkSwatchCell(name: "field", color: Chrome.field)
            }
            HStack(spacing: 12) {
                DarkSwatchCell(name: "popover", color: Chrome.popover)
                DarkSwatchCell(name: "backdropDeep", color: Chrome.backdropDeep)
                DarkSwatchCell(name: "sheetRing", color: Chrome.sheetRing)
            }
        }

        // Status chips on dark
        VStack(alignment: .leading, spacing: 10) {
            Text("ON-DARK STATUS CHIPS (14% self-tint)")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Chrome.sectionLabel)
            HStack(spacing: 8) {
                ChromeStatusChip(label: "passed", color: Chrome.success)
                ChromeStatusChip(label: "checking", color: Chrome.checking)
                ChromeStatusChip(label: "warning", color: Chrome.warning)
                ChromeStatusChip(label: "↥ 3 unpushed", color: Chrome.amberPill)
                ChromeStatusChip(label: "failed", color: Chrome.danger)
            }
            HStack(spacing: 12) {
                Circle().fill(Chrome.successDot).frame(width: Metrics.healthDot, height: Metrics.healthDot)
                Text("successDot").textStyle(TypeScale.monoTiny).foregroundStyle(Chrome.textMeta)
            }
        }
    }
    .padding(24)
    .frame(width: 560)
    .background(
        LinearGradient(
            colors: [Color(hex: 0x181A21), Chrome.backdropDeep],
            startPoint: .top, endPoint: .bottom
        )
    )
}
