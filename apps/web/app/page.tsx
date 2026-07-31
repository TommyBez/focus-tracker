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
    index: "01",
    title: "Choose the task",
    copy: "Select one open task. The rest of the list stays visible, but out of the chamber.",
  },
  {
    index: "02",
    title: "Set the block",
    copy: "Commit to 25, 50, or 90 minutes. Pause, resume, or finish deliberately.",
  },
  {
    index: "03",
    title: "Read the ledger",
    copy: "Completed focus and break sessions become a local record you can inspect by task or day.",
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

function ArrowIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 20 20" width="20" height="20">
      <path d="M3 10h13M11 5l5 5-5 5" fill="none" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 20 20" width="20" height="20">
      <path d="M10 2v10m0 0 4-4m-4 4L6 8M3 16h14" fill="none" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}

function DownloadActions({ compact = false }: { compact?: boolean }) {
  return (
    <div className={compact ? styles.downloadActionsCompact : styles.downloadActions}>
      <a className={styles.primaryCta} href={DOWNLOAD_URL}>
        <DownloadIcon />
        <span>Download beta for Apple Silicon</span>
      </a>
      <a className={styles.checksumLink} href={CHECKSUM_URL}>
        SHA-256 checksum
        <ArrowIcon />
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
            width={40}
            height={40}
            priority
            className={styles.brandIcon}
          />
          <span>Focus Tracker</span>
        </a>
        <nav className={styles.nav} aria-label="Primary navigation">
          <a href="#method">Method</a>
          <a href="#privacy">Privacy</a>
          <a href="#install">Install</a>
        </nav>
        <a className={styles.headerDownload} href={DOWNLOAD_URL}>
          Download beta
          <span aria-hidden="true">↓</span>
        </a>
      </header>

      <main id="main-content">
        <section className={styles.hero} id="top" aria-labelledby="hero-title">
          <div className={styles.heroGrid}>
            <div className={styles.heroCopy}>
              <p className={styles.eyebrow}>
                <span className={styles.liveDot} aria-hidden="true" />
                Native focus instrument · macOS beta
              </p>
              <h1 id="hero-title">
                Choose the work.
                <br />
                <em>Commit to the block.</em>
              </h1>
              <p className={styles.heroLead}>
                Focus Tracker turns an open task into a deliberate 25, 50, or 90 minute
                session—then writes the result to a private ledger on your Mac.
              </p>
              <DownloadActions />
              <p className={styles.buildNote}>
                macOS 11+ · Apple Silicon · Beta is ad-hoc signed and not notarized
              </p>
            </div>

            <div className={styles.instrumentWrap} aria-label="Focus Gate timer illustration">
              <div className={styles.instrumentGlow} aria-hidden="true" />
              <div className={styles.instrument}>
                <div className={styles.instrumentTopline}>
                  <span>FOCUS GATE / ACTIVE</span>
                  <span>LOCAL—01</span>
                </div>

                <div className={styles.activeTask}>
                  <div>
                    <span className={styles.instrumentLabel}>Committed task</span>
                    <strong>Shape the project brief</strong>
                  </div>
                  <span className={styles.taskMarker}>01</span>
                </div>

                <div className={styles.gateAssembly} aria-hidden="true">
                  <div className={styles.gateLabels}>
                    <span>0</span>
                    <span>25</span>
                    <span>50</span>
                  </div>
                  <div className={styles.gateRail}>
                    <span className={styles.gateFill} />
                    <span className={styles.gateHandle} />
                  </div>
                </div>

                <div className={styles.timerReadout}>
                  <span className={styles.instrumentLabel}>Time remaining</span>
                  <span className={styles.timerDigits}>24:36</span>
                  <span className={styles.timerState}>Block 01 · running</span>
                </div>

                <div className={styles.durationRail}>
                  <span className={styles.durationActive}>25 min</span>
                  <span>50 min</span>
                  <span>90 min</span>
                </div>

                <div className={styles.instrumentFooter}>
                  <span>PAUSE</span>
                  <span className={styles.instrumentRule} />
                  <span>FINISH</span>
                </div>
              </div>
            </div>
          </div>

          <div className={styles.signalStrip} aria-label="Focus Tracker workflow">
            <span>Task selected</span>
            <i aria-hidden="true" />
            <span>Block committed</span>
            <i aria-hidden="true" />
            <span>Ledger recorded</span>
          </div>

          <figure className={styles.productProof}>
            <div className={styles.productProofTopline}>
              <span>THE NATIVE APPLICATION</span>
              <span>RUNNING BLOCK · APPLE SILICON</span>
            </div>
            <div className={styles.productScreenshot}>
              <Image
                src="/product/focus-tracker-running.webp"
                alt="Focus Tracker running a 25 minute block for Shape the project brief, with two other open tasks in the local ledger"
                width={2360}
                height={1520}
                sizes="(max-width: 700px) calc(100vw - 28px), (max-width: 1280px) calc(100vw - 48px), 1240px"
              />
            </div>
            <figcaption>
              <span>Captured from the real retained-canvas desktop app.</span>
              <span>Isolated local dataset · no personal information</span>
            </figcaption>
          </figure>
        </section>

        <section className={styles.editorialIntro} aria-labelledby="intro-title">
          <p className={styles.sectionNumber}>01 / CONSTRAINT</p>
          <div>
            <h2 id="intro-title">
              A timer is easy.
              <br />
              <em>Choosing is the work.</em>
            </h2>
            <p>
              The Focus Gate asks for a task before it starts the clock. That small constraint
              turns a vague intention into a block with a name, a boundary, and a record.
            </p>
          </div>
        </section>

        <section className={styles.methodSection} id="method" aria-labelledby="method-title">
          <div className={styles.sectionHeading}>
            <div>
              <p className={styles.sectionNumber}>02 / THE METHOD</p>
              <h2 id="method-title">Task → block → ledger.</h2>
            </div>
            <p>
              One narrow loop, built to make commitment visible without turning your day into
              a dashboard.
            </p>
          </div>

          <ol className={styles.workflowList}>
            {workflow.map((step) => (
              <li key={step.index}>
                <span className={styles.workflowIndex}>{step.index}</span>
                <div className={styles.workflowGlyph} aria-hidden="true">
                  <span />
                </div>
                <h3>{step.title}</h3>
                <p>{step.copy}</p>
              </li>
            ))}
          </ol>
        </section>

        <section className={styles.featuresSection} aria-labelledby="features-title">
          <div className={styles.sectionHeading}>
            <div>
              <p className={styles.sectionNumber}>03 / INSTRUMENTS</p>
              <h2 id="features-title">Present when you need it.</h2>
            </div>
            <p>
              The main ledger, a compact controller, and durable recovery all work from the
              same local state.
            </p>
          </div>

          <div className={styles.featureGrid}>
            <article className={`${styles.feature} ${styles.quickFeature}`}>
              <div className={styles.featureMeta}>
                <span>⌘⇧F</span>
                <span>COMPACT CONTROL</span>
              </div>
              <h3>Quick Focus</h3>
              <p>
                Open a compact companion from the menu bar or keyboard. Select work and
                control the same running block without rebuilding context.
              </p>
              <div className={styles.quickMock} aria-hidden="true">
                <div className={styles.quickChrome}>
                  <span />
                  <span>QUICK FOCUS</span>
                  <span>×</span>
                </div>
                <div className={styles.quickTask}>Shape the project brief</div>
                <div className={styles.quickTime}>24:36</div>
                <div className={styles.quickControls}>
                  <span>PAUSE</span>
                  <span>FINISH</span>
                </div>
              </div>
            </article>

            <article className={`${styles.feature} ${styles.recoveryFeature}`}>
              <div className={styles.featureMeta}>
                <span>R—01</span>
                <span>DURABLE STATE</span>
              </div>
              <h3>Leave. Return. Continue.</h3>
              <p>
                Quit during a running or paused session and Focus Tracker recovers the block
                from SQLite when you reopen it.
              </p>
              <div className={styles.recoveryDial} aria-hidden="true">
                <span className={styles.recoveryOrbit} />
                <span className={styles.recoveryCore}>R</span>
                <span className={styles.recoveryTick}>SESSION RESTORED</span>
              </div>
            </article>

            <article className={`${styles.feature} ${styles.historyFeature}`}>
              <div className={styles.historyCopy}>
                <div className={styles.featureMeta}>
                  <span>L—07</span>
                  <span>LOCAL HISTORY</span>
                </div>
                <h3>Seven days, in context.</h3>
                <p>
                  Review recent focus and break sessions by day. The ledger shows what
                  happened; it does not grade your attention.
                </p>
              </div>
              <div className={styles.historyChart} aria-label="Illustration of a seven-day focus history">
                {[
                  ["M", 44],
                  ["T", 72],
                  ["W", 36],
                  ["T", 88],
                  ["F", 64],
                  ["S", 28],
                  ["S", 52],
                ].map(([day, value], index) => (
                  <div className={styles.chartDay} key={`${day}-${index}`}>
                    <div className={styles.chartTrack}>
                      <span style={{ height: `${value}%` }} />
                    </div>
                    <span>{day}</span>
                  </div>
                ))}
              </div>
            </article>
          </div>
        </section>

        <section className={styles.privacySection} id="privacy" aria-labelledby="privacy-title">
          <div className={styles.privacyGraphic} aria-hidden="true">
            <div className={styles.storagePlate}>
              <span className={styles.storageTop}>LOCAL / SQLITE</span>
              <span className={styles.storagePulse} />
              <span className={styles.storagePath}>focus.sqlite3</span>
            </div>
          </div>
          <div className={styles.privacyCopy}>
            <p className={styles.sectionNumber}>04 / PRIVATE BY ARCHITECTURE</p>
            <h2 id="privacy-title">Your focus history stays on this Mac.</h2>
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
                <dt>Cloud</dt>
                <dd>None</dd>
              </div>
            </dl>
          </div>
        </section>

        <section className={styles.installSection} id="install" aria-labelledby="install-title">
          <div className={styles.sectionHeading}>
            <div>
              <p className={styles.sectionNumber}>05 / INSTALL</p>
              <h2 id="install-title">Know what you are opening.</h2>
            </div>
            <p>
              This is an early public beta. The build is ad-hoc signed, not Developer ID
              signed, and not notarized by Apple.
            </p>
          </div>

          <div className={styles.installGrid}>
            <div className={styles.requirementsPanel}>
              <p className={styles.panelLabel}>SYSTEM REQUIREMENTS</p>
              <dl>
                <div>
                  <dt>Operating system</dt>
                  <dd>macOS 11 or later</dd>
                </div>
                <div>
                  <dt>Processor</dt>
                  <dd>Apple Silicon</dd>
                </div>
                <div>
                  <dt>Distribution</dt>
                  <dd>DMG · beta</dd>
                </div>
                <div>
                  <dt>Signature</dt>
                  <dd>Ad-hoc · not notarized</dd>
                </div>
              </dl>
              <DownloadActions compact />
            </div>

            <ol className={styles.installSteps}>
              <li>
                <span>01</span>
                <div>
                  <h3>Download and verify</h3>
                  <p>
                    Download the DMG from GitHub and compare it with the published{" "}
                    <a href={CHECKSUM_URL}>SHA-256 checksum</a>.
                  </p>
                </div>
              </li>
              <li>
                <span>02</span>
                <div>
                  <h3>Move it to Applications</h3>
                  <p>Open the DMG, then drag Focus Tracker into your Applications folder.</p>
                </div>
              </li>
              <li>
                <span>03</span>
                <div>
                  <h3>Review the Gatekeeper warning</h3>
                  <p>
                    Try opening the app once. If you trust the release, go to System Settings
                    → Privacy &amp; Security → Open Anyway. Read{" "}
                    <a href={APPLE_GATEKEEPER_URL} target="_blank" rel="noreferrer">
                      Apple&apos;s official guidance
                    </a>{" "}
                    before overriding the warning.
                  </p>
                </div>
              </li>
            </ol>
          </div>

          <aside className={styles.warning} aria-label="Beta security notice">
            <span className={styles.warningMark} aria-hidden="true">!</span>
            <p>
              <strong>Security notice.</strong> Apple warns that overriding security settings
              for unnotarized software carries risk. Proceed only if you trust the source and
              checksum; otherwise, do not open the beta.
            </p>
          </aside>
        </section>

        <section className={styles.faqSection} aria-labelledby="faq-title">
          <div className={styles.faqIntro}>
            <p className={styles.sectionNumber}>06 / FIELD NOTES</p>
            <h2 id="faq-title">Questions before the first block.</h2>
          </div>
          <div className={styles.faqList}>
            {faq.map((item, index) => (
              <details key={item.question} open={index === 0}>
                <summary>
                  <span>{item.question}</span>
                  <span className={styles.faqToggle} aria-hidden="true" />
                </summary>
                <p>{item.answer}</p>
              </details>
            ))}
          </div>
        </section>

        <section className={styles.finalCta} aria-labelledby="final-title">
          <div className={styles.finalSignal} aria-hidden="true">
            <span />
          </div>
          <p className={styles.sectionNumber}>READY / WHEN YOU ARE</p>
          <h2 id="final-title">One task. One block. A record you own.</h2>
          <p>Native on Apple Silicon. Local SQLite. No account and no cloud.</p>
          <DownloadActions />
        </section>
      </main>

      <footer className={styles.footer}>
        <div className={styles.footerBrand}>
          <Image src="/focus-tracker-icon.png" alt="" width={32} height={32} />
          <span>Focus Tracker</span>
        </div>
        <p>Built for deliberate work on macOS.</p>
        <div className={styles.footerLinks}>
          <a href={REPOSITORY_URL} target="_blank" rel="noreferrer">GitHub</a>
          <a href={CHECKSUM_URL}>Checksum</a>
          <a href="#top">Back to top ↑</a>
        </div>
      </footer>

      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(softwareJsonLd) }}
      />
    </>
  );
}
