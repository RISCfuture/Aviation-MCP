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

for (const button of document.querySelectorAll<HTMLButtonElement>(
  "[data-copy]",
)) {
  button.addEventListener("click", async () => {
    const text = document
      .getElementById(button.dataset.copy ?? "")
      ?.textContent?.trim();
    const status = document.getElementById("copy-status");
    if (!text || !status) return;
    try {
      await navigator.clipboard.writeText(text);
      status.textContent =
        button.dataset.copy === "endpoint-url"
          ? "Endpoint URL copied."
          : "Example prompt copied.";
      const label = button.firstChild;
      if (label) {
        const original = label.textContent;
        label.textContent = "Copied ";
        window.setTimeout(() => {
          label.textContent = original;
        }, 2000);
      }
    } catch {
      status.textContent =
        "Copy was unavailable. Select the text and copy it manually.";
      const element = document.getElementById(button.dataset.copy ?? "");
      if (element) {
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(element);
        selection?.removeAllRanges();
        selection?.addRange(range);
      }
    }
  });
}
