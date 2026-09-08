import "@fontsource-variable/inter/standard.css";
import "@fontsource-variable/inter/standard-italic.css";
import {
  ArrowUpRight01Icon,
  CodeIcon,
  DiscordIcon,
  FileDownloadIcon,
  GithubIcon,
  NewTwitterIcon,
  Pdf01Icon,
  SaladIcon,
  Shield01Icon,
  SourceCodeIcon,
} from "@hugeicons/core-free-icons";
import { HugeiconsIcon } from "@hugeicons/react";
import { SmoothCorners } from "@lisse/react";
import { motion } from "framer-motion";
import { useState, type ReactNode } from "react";

const links = {
  repository: "https://github.com/SidhuK/Parchley/",
  releases: "https://github.com/SidhuK/Parchley/releases",
  discord: "https://discord.com/invite/cNqrBfFx7D",
  x: "https://x.com/karat_sidhu",
  privacy: "https://github.com/SidhuK/Parchley/blob/main/PRIVACY.md",
} satisfies Record<string, string>;

const asset = (name: string) => `${import.meta.env.BASE_URL}${name}`;

const cardShadow = [
  { offsetX: 0, offsetY: 0, blur: 0, spread: 1, color: "#777777", opacity: 0.19 },
  { offsetX: 0, offsetY: 0, blur: 0, spread: 0.5, color: "#496342", opacity: 0.08 },
  { offsetX: 0, offsetY: 1, blur: 1, spread: 0, color: "#496342", opacity: 0.1 },
  { offsetX: 0, offsetY: 2, blur: 1, spread: -1, color: "#496342", opacity: 0.05 },
  { offsetX: 0, offsetY: 1, blur: 3, spread: 0, color: "#496342", opacity: 0.08 },
];

const actions = [
  { label: "Download Parchley", detail: "macOS 26 · Apple silicon", href: links.releases, icon: FileDownloadIcon },
  { label: "Read the source", detail: "SwiftUI · Rust · MIT", href: links.repository, icon: SourceCodeIcon },
  { label: "Join the Discord", detail: "Questions, ideas, and releases", href: links.discord, icon: DiscordIcon },
] as const;

function Stagger({ index, children }: { readonly index: number; readonly children: ReactNode }) {
  return (
    <motion.div
      initial={{ opacity: 0, filter: "blur(4px)" }}
      animate={{ opacity: 1, filter: "blur(0px)" }}
      transition={{ duration: 0.7, delay: 0.35 + index * 0.08, ease: [0.22, 0.61, 0.36, 1] }}
    >
      {children}
    </motion.div>
  );
}

function Divider() {
  return (
    <SmoothCorners asChild autoEffects={false} corners={{ radius: 0.625, smoothing: 0 }}>
      <div className="divider" role="separator" />
    </SmoothCorners>
  );
}

function Card({ children }: { readonly children: ReactNode }) {
  return (
    <SmoothCorners
      asChild
      autoEffects={false}
      corners={{ radius: 8, smoothing: 0.6 }}
      shadow={cardShadow}
    >
      {children}
    </SmoothCorners>
  );
}

function Header() {
  return (
    <header className="definition">
      <div className="definition-copy" role="group" aria-labelledby="parchley-heading">
        <Stagger index={0}>
          <div className="word-row">
            <HugeiconsIcon icon={SaladIcon} size={17} strokeWidth={1.7} aria-hidden="true" />
            <h1 id="parchley-heading">parchley</h1>
            <p aria-label="pronounced parch-lee, noun, parse plus parsley; documents, freshly chopped">
              <strong>/ˈpärCHlē/</strong> <em>noun</em> [<strong>parse</strong> + <strong>parsley</strong>; documents, freshly chopped]
            </p>
          </div>
        </Stagger>
        <div className="definitions">
          <Stagger index={1}><p><b>1</b> a Mac app that turns a PDF into editable Markdown.</p></Stagger>
          <Stagger index={2}><p><b>2</b> a quiet workspace for reading the source and fixing the result.</p></Stagger>
          <Stagger index={3}><p className="definition-indent"><b>b</b> private by default; parsing and OCR stay on the Mac.</p></Stagger>
          <Stagger index={4}><p><b>3</b> free and open source.</p></Stagger>
        </div>
      </div>
      <Stagger index={5}><Divider /></Stagger>
    </header>
  );
}

function Preview() {
  const [view, setView] = useState<"pdf" | "markdown">("pdf");
  const isPdf = view === "pdf";

  return (
    <Stagger index={7}>
      <section className="preview" aria-labelledby="preview-heading">
        <h2 id="preview-heading" className="sr-only">Parchley preview</h2>
        <div className="preview-mask" aria-hidden="true">
          <div className="grid-background" />
          <SmoothCorners asChild autoEffects={false} corners={{ radius: 7, smoothing: 0.6 }}>
            <div className="preview-window">
              <img src={asset(isPdf ? "pdf-review.png" : "markdown-editor.png")} alt="" />
            </div>
          </SmoothCorners>
        </div>
        <div className="preview-controls" role="group" aria-label="Choose preview">
          <Card>
            <div className="preview-toggle">
              <button type="button" onClick={() => setView("pdf")} aria-pressed={isPdf}>
                {isPdf ? <motion.span className="toggle-selection" layoutId="preview-selection" transition={{ type: "spring", stiffness: 500, damping: 38, mass: 0.6 }} /> : null}
                <span className="toggle-label"><HugeiconsIcon icon={Pdf01Icon} size={15} strokeWidth={1.7} /> PDF</span>
              </button>
              <button type="button" onClick={() => setView("markdown")} aria-pressed={!isPdf}>
                {!isPdf ? <motion.span className="toggle-selection" layoutId="preview-selection" transition={{ type: "spring", stiffness: 500, damping: 38, mass: 0.6 }} /> : null}
                <span className="toggle-label"><HugeiconsIcon icon={CodeIcon} size={15} strokeWidth={1.7} /> Markdown</span>
              </button>
            </div>
          </Card>
        </div>
      </section>
    </Stagger>
  );
}

function Actions() {
  return (
    <section className="actions" aria-labelledby="actions-heading">
      <h2 id="actions-heading" className="sr-only">Get Parchley</h2>
      <Stagger index={8}><Divider /></Stagger>
      <div className="action-list">
        {actions.map((action, index) => (
          <Stagger key={action.label} index={9 + index}>
            <a className="action-hitarea" href={action.href}>
              <Card>
                <span className="action-row">
                  <span className="action-icon" aria-hidden="true">
                    <HugeiconsIcon icon={action.icon} size={16} strokeWidth={1.7} />
                  </span>
                  <span className="action-label">{action.label}</span>
                  <span className="action-detail">{action.detail}</span>
                  <span className="action-arrow" aria-hidden="true">
                    <HugeiconsIcon icon={ArrowUpRight01Icon} size={16} strokeWidth={1.7} />
                  </span>
                </span>
              </Card>
            </a>
          </Stagger>
        ))}
      </div>
    </section>
  );
}

function Footer() {
  return (
    <Stagger index={12}>
      <footer>
        <nav aria-label="Footer">
          <a href={links.repository}><HugeiconsIcon icon={GithubIcon} size={13} strokeWidth={1.7} />GitHub</a>
          <a href={links.privacy}><HugeiconsIcon icon={Shield01Icon} size={13} strokeWidth={1.7} />Privacy</a>
          <a href={links.x}><HugeiconsIcon icon={NewTwitterIcon} size={13} strokeWidth={1.7} />Karat Sidhu</a>
        </nav>
        <span>PDF in. Markdown out.</span>
      </footer>
    </Stagger>
  );
}

function App() {
  return (
    <main>
      <article>
        <Header />
        <Stagger index={6}>
          <section className="intro">
            <p>
              Add a PDF and Parchley starts immediately. It works through batches one file at a time,
              keeps the original beside the output, and lets you edit or export clean Markdown. The
              bundled OCR model handles scanned pages without a download or cloud service.
            </p>
          </section>
        </Stagger>
        <Preview />
        <Actions />
        <Footer />
      </article>
    </main>
  );
}

export default App;
