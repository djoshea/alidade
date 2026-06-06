import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Vite config. `defineConfig` is a thin helper that gives editor IntelliSense
// for the config object; functionally it's an identity function.
export default defineConfig({
  plugins: [react()],
});
