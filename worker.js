import html from "./web/index.html";

export default {
  fetch(request) {
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
