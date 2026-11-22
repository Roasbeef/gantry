const toggle = document.querySelector("#toggle-base");
const label = document.querySelector("#outcome-label");
const result = document.querySelector("#outcome-text");
const normal = [...result.childNodes];
const stale = document.createDocumentFragment();
const branch = document.createElement("code");
const newerTip = document.createElement("code");

branch.textContent = "main";
newerTip.textContent = "b71e6a4";
stale.append(
  branch, " moved to ", newerTip,
  ". Git rejects the update. A fresh submission tests against the new tip.",
);

let baseMoved = false;
toggle.hidden = false;
toggle.addEventListener("click", () => {
  baseMoved = !baseMoved;
  label.textContent = baseMoved ? "Blocked" : "Landed";
  label.classList.toggle("blocked", baseMoved);
  result.replaceChildren(...(baseMoved ? [...stale.cloneNode(true).childNodes] : normal));
  toggle.textContent = baseMoved ? "Restore the tested base" : "Simulate a moved base";
});

if (navigator.clipboard?.writeText) {
  for (const button of document.querySelectorAll(".copy")) {
    const snippet = button.closest(".terminal").querySelector("pre code");
    button.hidden = false;
    button.addEventListener("click", async () => {
      const commands = snippet.cloneNode(true);
      commands.querySelectorAll(".prompt").forEach(prompt => prompt.remove());
      try {
        await navigator.clipboard.writeText(commands.textContent);
        button.textContent = "Copied";
      } catch {
        const range = document.createRange();
        range.selectNodeContents(snippet);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        button.textContent = "Press Ctrl+C or ⌘C";
      }
    });
  }
}
