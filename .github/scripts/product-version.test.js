"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  assertNativeSdkHashPreserved,
  bumpPatch,
  extractNativeSdkHash,
  isProductFileChange,
  isProductPath,
  parseVersion,
  readTopLevelVersion,
  replaceTopLevelVersion,
} = require("./product-version.js");

const APP_ZON = `.{
    .name = "focus-tracker",
    .version = "1.2.3",
    .nested = .{
        .version = "9.9.9",
    },
}
`;

const BUILD_ZON = `.{
    .name = .focus_tracker,
    .version = "1.2.3",
    .dependencies = .{
        .native_sdk = .{
            .url = "https://example.test/native/v0.6.2.tar.gz",
            .hash = "native_sdk-0.1.0-hzDzQp9I2gFMHD_R41bQ-uw8x1UlqXtr5Dqp_DP_2bxC",
        },
    },
}
`;

test("parses only the direct top-level ZON version", () => {
  assert.equal(readTopLevelVersion(APP_ZON), "1.2.3");
  assert.deepEqual(parseVersion("10.20.30"), { major: 10, minor: 20, patch: 30 });

  assert.throws(
    () => readTopLevelVersion(`.{\n    .nested = .{ .version = "1.2.3", },\n}\n`),
    /exactly one direct \.version/,
  );
  assert.throws(() => parseVersion("1.2.3-beta.1"), /stable semantic version/);
  assert.throws(() => parseVersion("01.2.3"), /stable semantic version/);
});

test("bumps exactly one patch component", () => {
  assert.equal(bumpPatch("0.0.0"), "0.0.1");
  assert.equal(bumpPatch("12.34.99"), "12.34.100");
  assert.throws(() => bumpPatch("1.2"), /stable semantic version/);
});

test("replaces the direct version without touching nested versions", () => {
  const updated = replaceTopLevelVersion(APP_ZON, "1.2.4");
  assert.equal(readTopLevelVersion(updated), "1.2.4");
  assert.match(updated, /        \.version = "9\.9\.9",/);
});

test("classifies only desktop product paths, including rename sources", () => {
  const included = [
    "apps/desktop/src/core.ts",
    "apps/desktop/app.zon",
    "apps/desktop/build.zig",
    "apps/desktop/build.zig.zon",
    "apps/desktop/assets/icon.png",
    "apps/desktop/packaging/macos/background.png",
    "apps/desktop/scripts/package-app.sh",
    "apps/desktop/package.json",
    "apps/desktop/tsconfig.json",
  ];
  const excluded = [
    "apps/web/src/page.tsx",
    "docs/release.md",
    ".github/workflows/product-version.yml",
    "package.json",
    "pnpm-lock.yaml",
    "README.md",
    "apps/desktop/README.md",
    "apps/desktop/turbo.json",
  ];

  for (const path of included) assert.equal(isProductPath(path), true, path);
  for (const path of excluded) assert.equal(isProductPath(path), false, path);
  assert.equal(
    isProductFileChange({ filename: "docs/old.md", previous_filename: "apps/desktop/src/removed.ts" }),
    true,
  );
});

test("extracts and preserves the pinned native_sdk-0.1.0 content hash", () => {
  const expected = "native_sdk-0.1.0-hzDzQp9I2gFMHD_R41bQ-uw8x1UlqXtr5Dqp_DP_2bxC";
  assert.equal(extractNativeSdkHash(BUILD_ZON), expected);

  const updated = replaceTopLevelVersion(BUILD_ZON, "1.2.4");
  assert.equal(assertNativeSdkHashPreserved(BUILD_ZON, updated), expected);
  assert.match(updated, new RegExp(expected.replaceAll("-", "\\-")));

  assert.throws(
    () => assertNativeSdkHashPreserved(BUILD_ZON, updated.replace(expected, `${expected}changed`)),
    /content hash changed/,
  );
});
