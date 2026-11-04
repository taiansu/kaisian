import html from "./web/index.html";
import favicon from "./web/favicon.svg";

export default {
  fetch(request) {
    const { pathname } = new URL(request.url);
    if (pathname === "/favicon.svg" || pathname === "/favicon.ico") {
      return new Response(favicon, {
        headers: { "Content-Type": "image/svg+xml; charset=utf-8" },
      });
    }

    if ((request.headers.get("Accept") || "").includes("text/html")) {
      return new Response(html, {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    return Response.redirect(
      "https://raw.githubusercontent.com/taiansu/kaisian/main/setup.sh",
      302,
    );
  },
};
