// Silth live reload (development only): reloads the page when the server restarts
// and hot-swaps stylesheets when assets change.
(() => {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  let wasConnected = false;
  const connect = () => {
    const ws = new WebSocket(`${proto}://${location.host}/_silth/livereload`);
    ws.onopen = () => { if (wasConnected) location.reload(); wasConnected = true; };
    ws.onmessage = (e) => {
      if (e.data === "css") {
        document.querySelectorAll('link[rel="stylesheet"]').forEach((link) => {
          const url = new URL(link.href); url.searchParams.set("v", Date.now()); link.href = url.toString();
        });
      } else if (e.data === "reload") location.reload();
    };
    ws.onclose = () => setTimeout(connect, 400);
  };
  connect();
})();
