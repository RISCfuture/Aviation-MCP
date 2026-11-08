export {};

/**
 * Turns each `[data-tabs]` block's list of anchor links into an ARIA tablist that shows one of the
 * sections they point to at a time. Without this script the links jump to sections that are all
 * shown.
 */
function enhanceTabs(container: HTMLElement) {
  const list = container.querySelector<HTMLElement>(".tab-list");
  if (!list) return;
  const tabs = [...list.querySelectorAll<HTMLAnchorElement>("a[href^='#']")];
  const panels = tabs.map((tab) => document.getElementById(tab.hash.slice(1)));
  if (panels.some((panel) => !panel)) return;

  list.setAttribute("role", "tablist");
  tabs.forEach((tab, index) => {
    const panel = panels[index] as HTMLElement;
    tab.setAttribute("role", "tab");
    tab.setAttribute("aria-controls", panel.id);
    panel.setAttribute("role", "tabpanel");
    panel.setAttribute("aria-labelledby", tab.id);
    panel.tabIndex = 0;
  });

  function select(index: number, { focus }: { focus: boolean }) {
    show(index);
    if (focus) tabs[index].focus();
    history.replaceState(null, "", tabs[index].hash);
  }

  function show(index: number) {
    tabs.forEach((tab, tabIndex) => {
      const selected = tabIndex === index;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      (panels[tabIndex] as HTMLElement).hidden = !selected;
    });
  }

  tabs.forEach((tab, index) => {
    tab.addEventListener("click", (event) => {
      event.preventDefault();
      select(index, { focus: false });
    });
  });

  list.addEventListener("keydown", (event) => {
    const current = tabs.indexOf(document.activeElement as HTMLAnchorElement);
    if (current < 0) return;
    const last = tabs.length - 1;
    const next = {
      ArrowRight: current === last ? 0 : current + 1,
      ArrowLeft: current === 0 ? last : current - 1,
      Home: 0,
      End: last,
    }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    select(next, { focus: true });
  });

  const linked = () => tabs.findIndex((tab) => tab.hash === location.hash);
  window.addEventListener("hashchange", () => {
    if (linked() >= 0) show(linked());
  });
  show(Math.max(linked(), 0));
}

for (const container of document.querySelectorAll<HTMLElement>("[data-tabs]"))
  enhanceTabs(container);
