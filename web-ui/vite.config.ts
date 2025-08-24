import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  root: ".",
  define: {
    "process.env.NODE_ENV": JSON.stringify(
      process.env.NODE_ENV || "production"
    ),
    "process.env": {},
    global: "globalThis",
  },
  build: {
    outDir: "../safari/Resources/dist",
    emptyOutDir: false,
    lib: {
      entry: "src/content.tsx",
      name: "IosWalletContent",
      formats: ["iife"],
      fileName: () => "content.iife.js",
    },
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
        manualChunks: undefined,
      },
    },
    sourcemap: false,
    minify: "esbuild",
    target: "es2020",
  },
  server: {
    port: 5173,
    open: true,
  },
});
