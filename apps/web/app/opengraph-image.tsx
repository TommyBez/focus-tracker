import { ImageResponse } from "next/og";

export const alt = "Focus Tracker: Choose the work. Commit to the block.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OpenGraphImage() {
  return new ImageResponse(
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        justifyContent: "space-between",
        position: "relative",
        overflow: "hidden",
        background: "#f2f1ec",
        color: "#111218",
        padding: "58px 68px 62px 86px",
        fontFamily: "Arial, sans-serif",
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: "0 auto 0 0",
          width: 18,
          display: "flex",
          background: "#2f57d7",
        }}
      />
      <div style={{ display: "flex", alignItems: "center", fontSize: 22, fontWeight: 700 }}>
        Focus Tracker
      </div>
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          fontSize: 84,
          fontWeight: 700,
          lineHeight: 0.96,
          letterSpacing: -5,
        }}
      >
        <span>Choose the work.</span>
        <span style={{ color: "#2f57d7" }}>Commit to the block.</span>
      </div>
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          paddingTop: 24,
          borderTop: "1px solid rgba(17,18,24,.28)",
          color: "#555760",
          fontSize: 18,
        }}
      >
        <span>Native macOS focus timer</span>
        <span>Apple Silicon · Local SQLite · No account</span>
      </div>
    </div>,
    size,
  );
}
