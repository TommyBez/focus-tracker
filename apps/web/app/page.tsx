import Image from "next/image";
import styles from "./page.module.css";
import {
  APPLE_GATEKEEPER_URL,
  CHECKSUM_URL,
  DOWNLOAD_URL,
  PRODUCT_NAME,
  REPOSITORY_URL,
  getSiteUrl,
} from "./site";

const workflow = [
  {
    title: "Choose",
    copy: "Select one open task before the clock can start. Your other work stays visible, but outside the block.",
    evidenceTitle: "Quick Focus",
    evidenceCopy: "Open the same task and timer from the menu bar or keyboard.",
  },
  {
    title: "Commit",
    copy: "Give it 25, 50, or 90 minutes. Pause, resume, or end the block deliberately.",
    evidenceTitle: "Session recovery",
    evidenceCopy: "Quit mid-block and restore the running or paused session from SQLite.",
  },
  {
    title: "Keep the record",
    copy: "Focus and break sessions are written to a local ledger you can review by task or day.",
    evidenceTitle: "Seven-day history",
    evidenceCopy: "Review recent work without streaks, scores, or attention grades.",
  },
] as const;

const faq = [
  {
    question: "Is this beta notarized by Apple?",
    answer:
      "No. This beta is ad-hoc signed, not signed with an Apple Developer ID, and not notarized. macOS will warn you on first launch. Only override Gatekeeper if you trust this GitHub release and have verified its checksum.",
  },
  {
    question: "Where does Focus Tracker keep my data?",
    answer:
      "Tasks, settings, and session history are stored in a local SQLite database on your Mac. There is no account and no cloud sync.",
  },
  {
    question: "Can I use it on an Intel Mac?",
    answer:
      "Not with this build. The current beta DMG is compiled for Apple Silicon Macs and requires macOS 11 or later.",
  },
  {
    question: "What happens if I quit during a block?",
    answer:
      "The timer uses a durable local session. Reopen Focus Tracker and it recovers the running or paused block from SQLite.",
  },
] as const;

function DownloadIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 20 20" width="18" height="18">
      <path d="M10 2v10m0 0 4-4m-4 4L6 8M3 16h14" fill="none" stroke="currentColor" strokeWidth="1.6" />
    </svg>
  );
}

function DownloadActions() {
  return (
    <div className={styles.downloadActions}>
      <a className={styles.primaryCta} href={DOWNLOAD_URL}>
        <DownloadIcon />
        <span>Download beta for Apple Silicon</span>
      </a>
      <a className={styles.checksumLink} href={CHECKSUM_URL}>
        View SHA-256 checksum
      </a>
    </div>
  );
}

export default function Home() {
  const softwareJsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: PRODUCT_NAME,
    description:
      "A native macOS focus timer for committing one task to a timed block and keeping a private local ledger.",
    applicationCategory: "ProductivityApplication",
    operatingSystem: "macOS 11 or later on Apple Silicon",
    url: getSiteUrl().toString(),
    downloadUrl: DOWNLOAD_URL,
    storageRequirements: "Local SQLite database",
  };

  return (
    <>
      <a className={styles.skipLink} href="#main-content">
        Skip to content
      </a>

      <header className={styles.siteHeader}>
        <a className={styles.brand} href="#top" aria-label="Focus Tracker home">
          <Image
            src="/focus-tracker-icon.png"
            alt=""
            width={36}
            height={36}
            loading="eager"
            className={styles.brandIcon}
          />
          <span>Focus Tracker</span>
        </a>
        <nav className={styles.nav} aria-label="Primary navigation">
          <a href="#method">How it works</a>
          <a href="#privacy">Privacy</a>
          <a href="#install">Install</a>
        </nav>
        <a className={styles.headerDownload} href={DOWNLOAD_URL}>
          Download for Apple Silicon
        </a>
      </header>

      <main id="main-content">
        <section className={styles.hero} id="top" aria-labelledby="hero-title">
          <div className={styles.heroGrid}>
            <h1 id="hero-title">
              Choose the work.
              <span>Commit to the block.</span>
            </h1>
            <div className={styles.heroIntro}>
              <p>
                Commit to 25, 50, or 90 minutes. Focus Tracker keeps the result in a private
                local ledger.
              </p>
              <DownloadActions />
              <p className={styles.platformNote}>
                Apple Silicon · macOS 11+ · Ad-hoc signed, not notarized
              </p>
            </div>
          </div>

          <figure className={styles.productProof}>
            <div className={styles.productScreenshot}>
              <Image
                src="/product/focus-tracker-running.webp"
                alt="Focus Tracker running a 25 minute block for Shape the project brief, with two other open tasks in the local ledger"
                width={2360}
                height={1520}
                sizes="(max-width: 700px) calc(100vw - 28px), (max-width: 1280px) calc(100vw - 56px), 1280px"
                preload
              />
            </div>
          </figure>
        </section>

        <section className={styles.methodSection} id="method" aria-labelledby="method-title">
          <div className={styles.sectionIntro}>
            <h2 id="method-title">Choosing is the work.</h2>
            <p>
              A timer cannot decide what deserves your next block. Focus Tracker gives that
              decision a task, a boundary, and a local record.
            </p>
          </div>

          <ol className={styles.workflowList}>
            {workflow.map((step) => (
              <li key={step.title}>
                <h3>{step.title}</h3>
                <p>{step.copy}</p>
                <div className={styles.workflowEvidence}>
                  <strong>{step.evidenceTitle}</strong>
                  <p>{step.evidenceCopy}</p>
                </div>
              </li>
            ))}
          </ol>
        </section>

        <section className={styles.privacySection} id="privacy" aria-labelledby="privacy-title">
          <div>
            <p className={styles.kicker}>Private by architecture</p>
            <h2 id="privacy-title">Your focus history stays on your Mac.</h2>
          </div>
          <div className={styles.privacyDetail}>
            <p>
              Tasks, preferences, and sessions are persisted in a local SQLite database.
              Focus Tracker has no account system and no cloud sync.
            </p>
            <dl className={styles.privacyFacts}>
              <div>
                <dt>Storage</dt>
                <dd>Local SQLite</dd>
              </div>
              <div>
                <dt>Account</dt>
                <dd>Not required</dd>
              </div>
              <div>
                <dt>Cloud sync</dt>
                <dd>None</dd>
              </div>
            </dl>
          </div>
        </section>

        <section className={styles.installSection} id="install" aria-labelledby="install-title">
          <div className={styles.installIntro}>
            <h2 id="install-title">Install the macOS beta.</h2>
            <p>
              This build is ad-hoc signed, not Developer ID signed, and not notarized by
              Apple. macOS will warn you before the first launch.
            </p>
            <dl className={styles.requirements}>
              <div>
                <dt>System</dt>
                <dd>macOS 11 or later</dd>
              </div>
              <div>
                <dt>Processor</dt>
                <dd>Apple Silicon</dd>
              </div>
              <div>
                <dt>Format</dt>
                <dd>DMG beta</dd>
              </div>
            </dl>
            <DownloadActions />
          </div>

          <div className={styles.installGuide}>
            <h3>Install and verify</h3>
            <ol>
              <li>
                <strong>Verify the download.</strong>
                <p>
                  Compare the DMG with the published <a href={CHECKSUM_URL}>SHA-256 checksum</a>.
                </p>
              </li>
              <li>
                <strong>Move it to Applications.</strong>
                <p>Open the DMG and drag Focus Tracker into your Applications folder.</p>
              </li>
              <li>
                <strong>Review the macOS warning.</strong>
                <p>
                  If you trust the release, follow{" "}
                  <a href={APPLE_GATEKEEPER_URL} target="_blank" rel="noreferrer">
                    Apple&apos;s official guidance
                  </a>{" "}
                  to open it. Otherwise, do not override Gatekeeper.
                </p>
              </li>
            </ol>
            <p className={styles.securityNotice}>
              Overriding macOS security settings for unnotarized software carries risk. Only
              proceed when you trust the source and the checksum matches.
            </p>
          </div>
        </section>

        <section className={styles.faqSection} aria-labelledby="faq-title">
          <h2 id="faq-title">Before your first block.</h2>
          <div className={styles.faqList}>
            {faq.map((item) => (
              <details key={item.question}>
                <summary>
                  <span>{item.question}</span>
                  <span className={styles.faqToggle} aria-hidden="true" />
                </summary>
                <p>{item.answer}</p>
              </details>
            ))}
          </div>
        </section>
      </main>

      <footer className={styles.footer}>
        <div className={styles.footerBrand}>
          <Image src="/focus-tracker-icon.png" alt="" width={28} height={28} />
          <span>Focus Tracker</span>
        </div>
        <p>Built for deliberate work on macOS.</p>
        <div className={styles.footerLinks}>
          <a href={REPOSITORY_URL} target="_blank" rel="noreferrer">GitHub</a>
          <a href={CHECKSUM_URL}>Checksum</a>
          <a href="#top">Back to top</a>
        </div>
      </footer>

      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(softwareJsonLd) }}
      />
    </>
  );
}
