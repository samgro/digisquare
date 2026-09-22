import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
    setupFiles: ["./test/setup-env.ts"],
    globals: false,
    restoreMocks: true,
    unstubEnvs: true,
  },
});
