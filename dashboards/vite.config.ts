import { fileURLToPath, URL } from "node:url";

import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      // The burn analysis is read from the pricing engine's real output rather
      // than a copy, so re-running `python quote.py` updates the dashboard.
      "@pricing": fileURLToPath(new URL("../pricing/out", import.meta.url)),
    },
  },
  server: {
    // Vite refuses to serve files outside the project root without this.
    fs: { allow: [".."] },
  },
});
