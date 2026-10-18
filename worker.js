import html from "./web/index.html";

const SCRIPT_BASE = "https://raw.githubusercontent.com/taiansu/kaisian/main";

export default {
  fetch(request) {
    // PowerShell's irm cannot be told apart by Accept, so Windows uses a path.
    if (new URL(request.url).pathname === "/win") {
      return Response.redirect(`${SCRIPT_BASE}/setup.ps1`, 302);
    }

    if ((request.headers.get("Accept") || "").includes("text/html")) {
      return new Response(html, {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    return Response.redirect(`${SCRIPT_BASE}/setup.sh`, 302);
  },
};
