"use strict";

const PRODUCT_FILES = new Set([
  "apps/desktop/app.zon",
  "apps/desktop/package.json",
  "apps/desktop/tsconfig.json",
]);

const PRODUCT_DIRECTORIES = [
  "apps/desktop/src/",
  "apps/desktop/assets/",
  "apps/desktop/packaging/",
  "apps/desktop/scripts/",
];

const VERSION_PATTERN = "(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)";

function scanLineBraces(line, initialDepth) {
  let depth = initialDepth;
  let inString = false;
  let escaped = false;

  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    const next = line[index + 1];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === '"') {
        inString = false;
      }
      continue;
    }

    if (character === "/" && next === "/") {
      break;
    }
    if (character === '"') {
      inString = true;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth < 0) {
        throw new Error("ZON structure closes a block before it is opened");
      }
    }
  }

  if (inString) {
    throw new Error("ZON metadata contains an unterminated string literal");
  }

  return depth;
}

function directStringField(source, field, valuePattern, label) {
  if (typeof source !== "string") {
    throw new TypeError(`${label} must be a string`);
  }

  const fieldPattern = new RegExp(
    `^[ \\t]*\\.${field}[ \\t]*=[ \\t]*"(${valuePattern})"[ \\t]*,[ \\t]*(?://.*)?$`,
  );
  const matches = [];
  let depth = 0;
  let offset = 0;

  for (const lineWithEnding of source.matchAll(/.*(?:\r\n|\n|$)/g)) {
    if (lineWithEnding[0] === "") {
      continue;
    }

    const line = lineWithEnding[0].replace(/(?:\r\n|\n)$/, "");
    const match = depth === 1 ? fieldPattern.exec(line) : null;
    if (match) {
      const openingQuote = line.indexOf('"', match.index);
      matches.push({
        value: match[1],
        valueStart: offset + openingQuote + 1,
        valueEnd: offset + openingQuote + 1 + match[1].length,
      });
    }

    depth = scanLineBraces(line, depth);
    offset += lineWithEnding[0].length;
  }

  if (depth !== 0) {
    throw new Error(`${label} has unbalanced braces`);
  }
  if (matches.length !== 1) {
    throw new Error(`${label} must contain exactly one direct .${field} string field`);
  }

  return matches[0];
}

function parseVersion(version, label = "version") {
  if (typeof version !== "string") {
    throw new TypeError(`${label} must be a string`);
  }

  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(version);
  if (!match) {
    throw new Error(`${label} must be a stable semantic version (major.minor.patch)`);
  }

  const components = match.slice(1).map(Number);
  if (!components.every(Number.isSafeInteger)) {
    throw new Error(`${label} contains an unsafe integer component`);
  }

  return {
    major: components[0],
    minor: components[1],
    patch: components[2],
  };
}

function readTopLevelVersion(source, label = "ZON metadata") {
  const match = directStringField(source, "version", VERSION_PATTERN, label);
  parseVersion(match.value, `${label} .version`);
  return match.value;
}

function replaceTopLevelVersion(source, nextVersion, label = "ZON metadata") {
  parseVersion(nextVersion, "replacement version");
  const match = directStringField(source, "version", VERSION_PATTERN, label);
  const updated = `${source.slice(0, match.valueStart)}${nextVersion}${source.slice(match.valueEnd)}`;

  if (readTopLevelVersion(updated, label) !== nextVersion) {
    throw new Error(`failed to update ${label} .version`);
  }
  return updated;
}

function bumpPatch(version) {
  const parsed = parseVersion(version);
  if (parsed.patch === Number.MAX_SAFE_INTEGER) {
    throw new Error("version patch cannot be incremented safely");
  }
  return `${parsed.major}.${parsed.minor}.${parsed.patch + 1}`;
}

function isProductPath(path) {
  if (typeof path !== "string" || path === "" || path.includes("\\")) {
    return false;
  }

  return (
    PRODUCT_FILES.has(path) ||
    path.startsWith("apps/desktop/build.zig") ||
    PRODUCT_DIRECTORIES.some((directory) => path.startsWith(directory) && path.length > directory.length)
  );
}

function isProductFileChange(file) {
  return Boolean(
    file &&
      (isProductPath(file.filename) ||
        (typeof file.previous_filename === "string" && isProductPath(file.previous_filename))),
  );
}

function findMatchingBrace(source, openingBrace) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  let inLineComment = false;

  for (let index = openingBrace; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];

    if (inLineComment) {
      if (character === "\n") {
        inLineComment = false;
      }
      continue;
    }
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === '"') {
        inString = false;
      }
      continue;
    }
    if (character === "/" && next === "/") {
      inLineComment = true;
      index += 1;
    } else if (character === '"') {
      inString = true;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) {
        return index;
      }
    }
  }

  throw new Error("native_sdk dependency block has unbalanced braces");
}

function extractNativeSdkHash(source, label = "build.zig.zon") {
  if (typeof source !== "string") {
    throw new TypeError(`${label} must be a string`);
  }

  const blockMatches = [...source.matchAll(/^[ \t]*\.native_sdk[ \t]*=[ \t]*\.\{[ \t]*(?:\/\/.*)?$/gm)];
  if (blockMatches.length !== 1) {
    throw new Error(`${label} must contain exactly one native_sdk dependency block`);
  }

  const blockStart = blockMatches[0].index + blockMatches[0][0].lastIndexOf("{");
  const blockEnd = findMatchingBrace(source, blockStart);
  const block = source.slice(blockStart, blockEnd + 1);
  const hash = directStringField(block, "hash", "native_sdk-0\\.1\\.0-[A-Za-z0-9_-]+", `${label} native_sdk`)
    .value;

  return hash;
}

function assertNativeSdkHashPreserved(before, after, label = "build.zig.zon") {
  const beforeHash = extractNativeSdkHash(before, `${label} before update`);
  const afterHash = extractNativeSdkHash(after, `${label} after update`);
  if (beforeHash !== afterHash) {
    throw new Error(`${label} native_sdk content hash changed during the version update`);
  }
  return beforeHash;
}

module.exports = {
  assertNativeSdkHashPreserved,
  bumpPatch,
  extractNativeSdkHash,
  isProductFileChange,
  isProductPath,
  parseVersion,
  readTopLevelVersion,
  replaceTopLevelVersion,
};
