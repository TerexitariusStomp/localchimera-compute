/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        'deep-space': {
          900: '#0a0a0f',
          800: '#1a1a2e',
        },
        'electric-blue': {
          500: '#00d9ff',
          600: '#0066ff',
        },
        'vibrant-purple': {
          500: '#a855f7',
          600: '#7c3aed',
        },
        'warm-orange': {
          500: '#ff6b35',
          600: '#f97316',
        },
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
        mono: ['JetBrains Mono', 'monospace'],
      },
    },
  },
  plugins: [],
}
