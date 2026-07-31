import { ImageResponse } from "next/og";

export const alt = "Focus Tracker — Choose the work. Commit to the block.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OpenGraphImage() {
  return new ImageResponse(
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        position: "relative",
        overflow: "hidden",
        background: "#0d0f13",
        color: "#f3f1eb",
        padding: "64px 70px",
        fontFamily: "Georgia, serif",
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          background:
            "radial-gradient(circle at 80% 50%, rgba(49,86,217,.42), transparent 32%)",
        }}
      />
      <div style={{ display: "flex", flexDirection: "column", justifyContent: "space-between", width: "64%" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14, fontFamily: "Arial, sans-serif", fontSize: 18, letterSpacing: 2 }}>
          <span style={{ width: 10, height: 10, display: "flex", borderRadius: 10, background: "#5f7eff" }} />
          FOCUS TRACKER · MACOS BETA
        </div>
        <div style={{ display: "flex", flexDirection: "column", fontSize: 78, lineHeight: 0.98, letterSpacing: -3 }}>
          <span>Choose the work.</span>
          <span style={{ color: "#7e97ff", fontStyle: "italic" }}>Commit to the block.</span>
        </div>
        <div style={{ display: "flex", fontFamily: "Arial, sans-serif", fontSize: 18, color: "#a7a8ab" }}>
          Native Apple Silicon · Local SQLite · No account
        </div>
      </div>
      <div
        style={{
          width: 310,
          height: 390,
          margin: "52px 0 0 auto",
          padding: 24,
          display: "flex",
          flexDirection: "column",
          border: "1px solid #667fdc",
          borderRadius: "3px 22px 3px 3px",
          background: "linear-gradient(160deg,#1b1e25,#111319)",
          boxShadow: "0 28px 80px rgba(0,0,0,.5)",
        }}
      >
        <div style={{ display: "flex", justifyContent: "space-between", fontFamily: "Arial, sans-serif", fontSize: 11, color: "#818691", letterSpacing: 1 }}>FOCUS GATE <span>01</span></div>
        <div style={{ display: "flex", marginTop: 30, padding: "16px 0", borderTop: "1px solid #343740", borderBottom: "1px solid #343740", fontSize: 22 }}>Shape the brief</div>
        <div style={{ display: "flex", flex: 1, alignItems: "center", justifyContent: "center", fontFamily: "Arial, sans-serif", fontSize: 72, fontWeight: 300, letterSpacing: -5 }}>24:36</div>
        <div style={{ display: "flex", height: 38, alignItems: "center", justifyContent: "center", border: "1px solid #394253", background: "rgba(49,86,217,.16)", color: "#8ea3ff", fontFamily: "Arial, sans-serif", fontSize: 11, letterSpacing: 2 }}>25 MIN · RUNNING</div>
      </div>
    </div>,
    size,
  );
}
