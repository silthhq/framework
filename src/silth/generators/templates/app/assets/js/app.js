// Application entry point (ES module, loaded through the import map).
import { silth } from "silth";

window.addEventListener("silth:toast", (event) => {
  const toast = document.createElement("div");
  toast.className = "toast";
  toast.textContent = event.detail?.message ?? "Done";
  document.body.appendChild(toast);
  setTimeout(() => toast.remove(), 2500);
});

export default silth;
