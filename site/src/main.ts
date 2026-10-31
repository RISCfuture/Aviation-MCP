export {};

const header = document.querySelector<HTMLElement>(".header");
const sectionLinks = [
  ...document.querySelectorAll<HTMLAnchorElement>('.header nav a[href^="#"]'),
].flatMap((link) => {
  const section = document.getElementById(link.hash.slice(1));
  return section ? [{ link, section }] : [];
});

function updateActiveSection() {
  const headerBottom = header?.getBoundingClientRect().bottom ?? 0;
  const readingPosition =
    headerBottom + (window.innerHeight - headerBottom) / 3;
  const active =
    sectionLinks.findLast(
      ({ section }) => section.getBoundingClientRect().top <= readingPosition,
    ) ?? sectionLinks[0];

  for (const entry of sectionLinks) {
    if (entry === active) entry.link.setAttribute("aria-current", "location");
    else entry.link.removeAttribute("aria-current");
  }
}

let navigationUpdatePending = false;
function scheduleNavigationUpdate() {
  if (navigationUpdatePending) return;
  navigationUpdatePending = true;
  window.requestAnimationFrame(() => {
    navigationUpdatePending = false;
    updateActiveSection();
  });
}

window.addEventListener("scroll", scheduleNavigationUpdate, { passive: true });
window.addEventListener("resize", scheduleNavigationUpdate);
window.addEventListener("pageshow", scheduleNavigationUpdate);
void document.fonts.ready.then(scheduleNavigationUpdate);
updateActiveSection();

/** Returns a callback that labels the button "Copied" for two seconds. */
function copiedFeedback(button: HTMLButtonElement) {
  const label = button.firstChild;
  const original = label?.textContent ?? "";
  let resetTimer: number | undefined;

  return () => {
    if (!label) return;
    window.clearTimeout(resetTimer);
    label.textContent = "Copied ";
    resetTimer = window.setTimeout(() => {
      label.textContent = original;
    }, 2000);
  };
}

function selectContents(element: HTMLElement) {
  const selection = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(element);
  selection?.removeAllRanges();
  selection?.addRange(range);
}

for (const button of document.querySelectorAll<HTMLButtonElement>(
  "[data-copy]",
)) {
  const showCopied = copiedFeedback(button);
  button.addEventListener("click", async () => {
    const source = document.getElementById(button.dataset.copy ?? "");
    const text = source?.textContent?.trim();
    const status = document.getElementById("copy-status");
    if (!source || !text || !status) return;
    try {
      await navigator.clipboard.writeText(text);
      status.textContent =
        button.dataset.copyStatus ?? "Example prompt copied.";
      showCopied();
    } catch {
      status.textContent =
        "Copy was unavailable. Select the text and copy it manually.";
      selectContents(source);
    }
  });
}
