import {Terminal} from "../../vendor/xterm/xterm.mjs"

const ANSI = /\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-B]/g

const isWide = cp =>
  (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) ||
  (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) ||
  (cp >= 0xfe30 && cp <= 0xfe4f) || (cp >= 0xff00 && cp <= 0xff60) ||
  (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1faff) ||
  cp >= 0x20000

const displayWidth = line => {
  let width = 0
  for (const ch of line.replace(ANSI, "")) width += isWide(ch.codePointAt(0)) ? 2 : 1
  return width
}

// Renders `pane.read` snapshots; the xterm grid is sized to the herdr pane so lines never re-wrap.
export default {
  mounted() {
    this.term = new Terminal({
      disableStdin: true,
      cursorInactiveStyle: "none",
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
      fontSize: 13,
      lineHeight: 1.15,
      scrollback: 0,
      theme: {background: "#09090b", foreground: "#e4e4e7"},
    })
    this.term.open(this.el)

    this.handleEvent("term:frame", ({text}) => {
      const lines = text.split(/\r?\n/)
      const cols = Math.max(20, ...lines.map(displayWidth))
      const rows = Math.max(1, lines.length)
      if (cols !== this.term.cols || rows !== this.term.rows) this.term.resize(cols, rows)
      this.term.write("\x1b[?25l\x1b[H\x1b[2J" + lines.join("\r\n"))
    })

    this.handleEvent("term:clear", () => this.term.reset())
  },

  destroyed() {
    this.term.dispose()
  },
}
