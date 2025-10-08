import path from "path";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import removeConsole from "vite-plugin-remove-console";

const isDev = process.env.NODE_ENV === "development";

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    // removeConsole({
    //   includes: !isDev ? ["log", "info", "debug"] : [],
    // }),
  ],
  root: ".",
  define: {
    "process.env.NODE_ENV": JSON.stringify(
      process.env.NODE_ENV || "production"
    ),
    global: "globalThis",
  },
  build: {
    outDir: "../safari/Resources/dist",
    emptyOutDir: false,
    lib: {
      entry: "src/main.tsx",
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
    minify: isDev ? false : "esbuild",
    target: "es2020",
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  server: {
    port: 5173,
    open: true,
  },
});
