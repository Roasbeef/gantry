// The graph shows the landed path by default, and the toggle swaps in the
// rows for a target that moved during the build. Without JavaScript the
// landed path stays visible and the toggle is hidden.
const graph = document.querySelector(".graph");
const toggle = document.querySelector(".toggle");
const pill = graph.querySelector(".pill");
const statusText = graph.querySelector(".status-text");

const outcomes = {
  landed: { pill: "Landed", text: "<code>main</code>: <code>53ad9e2</code> → <code>c42f8b7</code>" },
  blocked: { pill: "Blocked", text: "<code>main</code> stays at <code>b71e6a4</code>. Submit again." },
};

function show(outcome) {
  graph.dataset.outcome = outcome;
  pill.textContent = outcomes[outcome].pill;
  statusText.innerHTML = outcomes[outcome].text;
  for (const button of toggle.querySelectorAll("button")) {
    button.setAttribute("aria-pressed", String(button.dataset.outcome === outcome));
  }
}

toggle.hidden = false;
toggle.addEventListener("click", event => {
  const button = event.target.closest("button[data-outcome]");
  if (button) show(button.dataset.outcome);
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
        button.textContent = "Select and copy";
      }
    });
  }
}
