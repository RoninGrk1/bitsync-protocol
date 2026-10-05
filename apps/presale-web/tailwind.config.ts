import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        ink: { DEFAULT: "#050816", soft: "#0B1224", card: "#111827" },
        bit: { DEFAULT: "#F8FAFC", muted: "#94A3B8" },
        sync: { DEFAULT: "#1E90FF", glow: "#38BDF8", deep: "#0B4F8A" },
      },
      backgroundImage: {
        "horizon-glow":
          "radial-gradient(ellipse at 50% 100%, rgba(30,144,255,0.35), transparent 60%), radial-gradient(ellipse at 80% 0%, rgba(56,189,248,0.12), transparent 50%)",
      },
      fontFamily: {
        display: ["ui-sans-serif", "system-ui", "Segoe UI", "sans-serif"],
      },
    },
  },
  plugins: [],
};
export default config;
