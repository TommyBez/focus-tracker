export const PRODUCT_NAME = "Focus Tracker";
export const DOWNLOAD_URL =
  "https://github.com/TommyBez/focus-tracker/releases/latest/download/Focus-Tracker-macOS-arm64.dmg";
export const CHECKSUM_URL = `${DOWNLOAD_URL}.sha256`;
export const REPOSITORY_URL = "https://github.com/TommyBez/focus-tracker";
export const APPLE_GATEKEEPER_URL =
  "https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac";

export function getSiteUrl(): URL {
  const productionHost = process.env.VERCEL_PROJECT_PRODUCTION_URL;

  return new URL(
    productionHost
      ? `https://${productionHost}`
      : "https://focus-tracker.vercel.app",
  );
}
