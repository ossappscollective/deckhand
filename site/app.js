// Deckhand site: the download button points at the latest release, and the build snippet can be copied.
(() => {
  if (location.search.includes("shot")) document.body.classList.add("shotmode");

  const repo = "ossappscollective/deckhand";
  const buttons = document.querySelectorAll("[data-download]");
  const note = document.querySelector("[data-release-note]");
  const version = document.querySelector("[data-version]");

  fetch(`https://api.github.com/repos/${repo}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((release) => {
      const dmg = (release.assets || []).find((a) => a.name.endsWith(".dmg"));
      const name = (release.tag_name || "").replace(/^v/, "");
      buttons.forEach((button) => {
        if (dmg) button.href = dmg.browser_download_url;
        const label = button.querySelector("[data-download-label]");
        if (label && name) label.textContent = `Download Deckhand ${name}`;
      });
      if (version && name) version.textContent = `Version ${name}. Free and open source, no account, no telemetry.`;
      if (note && dmg) note.textContent = `Deckhand ${name} for macOS, signed and notarized (${(dmg.size / 1048576).toFixed(0)} MB).`;
    })
    .catch(() => {
      // no release yet, or the API is rate limited: the buttons keep pointing at the releases page
    });

  const copy = document.querySelector("[data-copy]");
  if (copy) {
    copy.addEventListener("click", async () => {
      const text = document.getElementById("build").innerText;
      try {
        await navigator.clipboard.writeText(text);
        copy.textContent = "Copied";
      } catch {
        copy.textContent = "Select and copy";
      }
      setTimeout(() => (copy.textContent = "Copy"), 1800);
    });
  }
})();
