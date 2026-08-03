//! Cobalt Instrument design tokens.
//!
//! This module deliberately starts from Native SDK's house theme for every
//! live appearance. It only adjusts the product's quiet visual register:
//! typography, macro spacing, radii, neutral surfaces/borders, and the
//! semantic accent bundle. Motion, control metrics, density behavior, and
//! every high-contrast color remain framework-owned.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const Options = struct {
    /// The live platform appearance supplied by Native SDK.
    appearance: native_sdk.Appearance = .{},
    /// Keep density caller-owned so compact/regular/spacious all retain
    /// the framework's complete control-metric behavior.
    density: canvas.Density = .regular,
    /// Pass `runner.manifestThemeAccent()` here. Null preserves house's
    /// monochrome primary; high contrast always ignores the brand accent.
    accent: ?canvas.Color = null,
};

/// Resolve the complete Cobalt Instrument register for one live appearance.
///
/// Suitable for an app-owned `tokens_fn` after the model mirrors Native
/// SDK's appearance channel. The caller should invoke this again whenever
/// light/dark, high contrast, reduced motion, or density changes.
pub fn tokens(options: Options) canvas.DesignTokens {
    const scheme: canvas.ColorScheme = switch (options.appearance.color_scheme) {
        .light => .light,
        .dark => .dark,
    };
    const contrast: canvas.ColorContrast = if (options.appearance.high_contrast)
        .high
    else
        .standard;

    var resolved = canvas.DesignTokens.theme(.{
        .color_scheme = scheme,
        .contrast = contrast,
        .density = options.density,
        .reduce_motion = options.appearance.reduce_motion,
        .pack = .house,
    });

    resolved = resolved.withOverrides(.{
        .typography = .{
            // Retain the restrained house ladder; give instrument readouts
            // one clearer display step without changing the bundled face.
            .body_size = 14,
            .label_size = 13,
            .title_size = 20,
            .button_size = 13,
            .heading_size = 28,
            .display_size = 56,
        },
        .spacing = .{
            .xs = 4,
            .sm = 8,
            .md = 12,
            .lg = 16,
            .xl = 28,
        },
        .radius = .{
            // Tighter AppKit-like controls, with larger radii reserved for
            // genuine instruments instead of turning every control into a pill.
            .sm = 4,
            .md = 6,
            .lg = 10,
            .xl = 14,
        },
    });

    // Accessibility owns high contrast. In standard contrast, derive every
    // neutral from the active house palette instead of pinning light colors
    // into dark mode.
    if (contrast == .standard) {
        resolved = resolved.withOverrides(.{
            .colors = quietSurfaceOverrides(resolved.colors, scheme),
        });

        // Native SDK's semantic bundle derives readable knockout ink, a
        // scheme-aware focus ring, and the slider active range. This is the
        // same safe accent path used by app.zon's `theme_accent` support.
        if (options.accent) |accent| {
            resolved = resolved.withOverrides(canvas.accentOverrides(accent, scheme));
        }

        // Resolve control colors only after the semantic accent bundle so
        // progress and focus visuals follow the caller's live accent.
        const colors = resolved.colors;
        const control_border = withAlpha(colors.text, switch (scheme) {
            // These floors composite to at least 3:1 against the actual house
            // backgrounds; the quieter colors.border remains decorative only.
            .light => 0.44,
            .dark => 0.36,
        });
        const progress_track = mix(colors.background, colors.text, switch (scheme) {
            .light => 0.07,
            .dark => 0.14,
        });

        resolved = resolved.withOverrides(.{
            .stroke = .{
                .focus = 1.5,
                .focus_offset = 1,
            },
            .controls = .{
                .button_default = .{ .radius = 6 },
                .button_primary = .{ .radius = 6 },
                .button_secondary = .{ .radius = 6 },
                .button_outline = .{ .radius = 6 },
                .button_ghost = .{ .radius = 6 },
                .button_destructive = .{ .radius = 6 },
                .toggle_button = .{ .radius = 6 },
                .tabs = .{
                    .border = control_border,
                    .radius = 8,
                    .stroke_width = 1,
                },
                .text_field = .{
                    .background = colors.background,
                    .border = control_border,
                    .radius = 5,
                    .stroke_width = 1,
                },
                .checkbox = .{
                    .background = colors.background,
                    .hover_background = colors.surface_subtle,
                    .border = withAlpha(colors.text, switch (scheme) {
                        .light => 0.44,
                        .dark => 0.50,
                    }),
                    .radius = 3,
                    .stroke_width = 1,
                },
                .progress = .{
                    .background = progress_track,
                    .active_background = colors.accent,
                    .radius = 2,
                },
                // The selected task is the one a block will run against, so
                // its row reads as a choice rather than a neutral hover
                // leftover. The wash stays a tint of the live accent, which
                // high contrast still overrides wholesale.
                .list_item = .{
                    .active_background = withAlpha(colors.accent, switch (scheme) {
                        .light => 0.12,
                        .dark => 0.20,
                    }),
                    .radius = 5,
                },
            },
        });
    }

    return resolved;
}

fn quietSurfaceOverrides(
    colors: canvas.ColorTokens,
    scheme: canvas.ColorScheme,
) canvas.ColorTokenOverrides {
    const surface_ink: f32 = switch (scheme) {
        .light => 0.012,
        .dark => 0.050,
    };
    const subtle_ink: f32 = switch (scheme) {
        .light => 0.035,
        .dark => 0.100,
    };
    const border_alpha: f32 = switch (scheme) {
        .light => 0.14,
        .dark => 0.18,
    };

    return .{
        .surface = mix(colors.background, colors.text, surface_ink),
        .surface_subtle = mix(colors.background, colors.text, subtle_ink),
        .border = withAlpha(colors.text, border_alpha),
        .text_muted = mix(colors.background, colors.text, switch (scheme) {
            .light => 0.60,
            .dark => 0.70,
        }),
    };
}

fn mix(base: canvas.Color, ink: canvas.Color, amount: f32) canvas.Color {
    const keep = 1.0 - amount;
    return .{
        .r = base.r * keep + ink.r * amount,
        .g = base.g * keep + ink.g * amount,
        .b = base.b * keep + ink.b * amount,
        .a = base.a * keep + ink.a * amount,
    };
}

fn withAlpha(color: canvas.Color, alpha: f32) canvas.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha };
}

test "high contrast and reduced motion remain framework-owned" {
    const appearance: native_sdk.Appearance = .{
        .color_scheme = .dark,
        .high_contrast = true,
        .reduce_motion = true,
    };
    const base = canvas.DesignTokens.theme(.{
        .color_scheme = .dark,
        .contrast = .high,
        .density = .compact,
        .reduce_motion = true,
        .pack = .house,
    });
    const actual = tokens(.{
        .appearance = appearance,
        .density = .compact,
        .accent = base.colors.info,
    });

    try std.testing.expectEqualDeep(base.colors, actual.colors);
    try std.testing.expectEqualDeep(base.stroke, actual.stroke);
    try std.testing.expectEqualDeep(base.controls, actual.controls);
    try std.testing.expectEqualDeep(base.motion, actual.motion);
    try std.testing.expectEqual(canvas.Density.compact, actual.density);
}

test "standard appearance applies accent and native control refinements" {
    const base = canvas.DesignTokens.theme(.{
        .color_scheme = .light,
        .contrast = .standard,
        .pack = .house,
    });
    const actual = tokens(.{ .accent = base.colors.info });
    const dark = tokens(.{ .appearance = .{ .color_scheme = .dark } });

    try std.testing.expectEqualDeep(base.colors.info, actual.colors.accent);
    try std.testing.expectEqualDeep(base.colors.background, actual.colors.background);
    try std.testing.expectEqualDeep(base.colors.surface_pressed, actual.colors.surface_pressed);
    try std.testing.expectEqual(@as(f32, 0.14), actual.colors.border.a);
    try std.testing.expectEqual(@as(f32, 0.18), dark.colors.border.a);
    try std.testing.expectEqual(@as(f32, 1.5), actual.stroke.focus);
    try std.testing.expectEqual(@as(f32, 1), actual.stroke.focus_offset);
    for ([_]f32{
        actual.controls.button_default.radius.?,
        actual.controls.button_primary.radius.?,
        actual.controls.button_secondary.radius.?,
        actual.controls.button_outline.radius.?,
        actual.controls.button_ghost.radius.?,
        actual.controls.button_destructive.radius.?,
        actual.controls.toggle_button.radius.?,
    }) |radius| try std.testing.expectEqual(@as(f32, 6), radius);
    try std.testing.expectEqual(@as(f32, 8), actual.controls.tabs.radius.?);
    try std.testing.expectEqual(@as(f32, 0.44), actual.controls.tabs.border.?.a);
    try std.testing.expectEqual(@as(f32, 0.36), dark.controls.tabs.border.?.a);
    try std.testing.expectEqual(@as(f32, 1), actual.controls.tabs.stroke_width.?);
    try std.testing.expectEqual(@as(f32, 5), actual.controls.text_field.radius.?);
    try std.testing.expectEqual(@as(f32, 0.44), actual.controls.text_field.border.?.a);
    try std.testing.expectEqual(@as(f32, 0.36), dark.controls.text_field.border.?.a);
    try std.testing.expectEqual(@as(f32, 1), actual.controls.text_field.stroke_width.?);
    try std.testing.expectEqual(@as(f32, 3), actual.controls.checkbox.radius.?);
    try std.testing.expectEqual(@as(f32, 0.44), actual.controls.checkbox.border.?.a);
    try std.testing.expectEqual(@as(f32, 0.50), dark.controls.checkbox.border.?.a);
    try std.testing.expectEqual(@as(f32, 1), actual.controls.checkbox.stroke_width.?);
    try std.testing.expectEqualDeep(
        mix(actual.colors.background, actual.colors.text, 0.07),
        actual.controls.progress.background.?,
    );
    try std.testing.expectEqualDeep(actual.colors.accent, actual.controls.progress.active_background.?);
    try std.testing.expectEqual(@as(f32, 2), actual.controls.progress.radius.?);
    try std.testing.expectEqual(@as(f32, 5), actual.controls.list_item.radius.?);
    try std.testing.expectEqualDeep(
        withAlpha(actual.colors.accent, 0.12),
        actual.controls.list_item.active_background.?,
    );
    try std.testing.expectEqual(@as(f32, 0.20), dark.controls.list_item.active_background.?.a);
}
