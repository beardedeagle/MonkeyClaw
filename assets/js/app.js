// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/monkey_claw"
import topbar from "../vendor/topbar"

const Hooks = {
  ScrollDown: {
    mounted() {
      this.scrollToBottom()
      this.addCopyButtons()
    },
    updated() {
      this.scrollToBottom()
      this.addCopyButtons()
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    },
    addCopyButtons() {
      this.el.querySelectorAll("pre:not([data-copy])").forEach(pre => {
        pre.setAttribute("data-copy", "true")
        pre.classList.add("relative", "group")
        const btn = document.createElement("button")
        btn.className =
          "absolute top-1.5 right-1.5 px-2 py-0.5 text-xs rounded " +
          "bg-base-100/80 hover:bg-base-100 text-base-content/50 " +
          "hover:text-base-content opacity-0 group-hover:opacity-100 " +
          "transition-all cursor-pointer"
        btn.textContent = "Copy"
        btn.addEventListener("click", () => {
          const code = pre.querySelector("code") || pre
          navigator.clipboard.writeText(code.textContent).then(() => {
            btn.textContent = "Copied!"
            setTimeout(() => { btn.textContent = "Copy" }, 2000)
          })
        })
        pre.appendChild(btn)
      })
    }
  },
  ChatInput: {
    mounted() {
      this.textarea = this.el.querySelector("textarea[name='message']")
      if (!this.textarea) return

      // Auto-resize on input
      this.textarea.addEventListener("input", () => this.resize())

      // Enter sends, Shift+Enter adds newline
      this.textarea.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
          e.preventDefault()
          if (this.textarea.value.trim()) {
            this.el.requestSubmit()
          }
        }
      })

      // Clear and refocus after send
      this.handleEvent("clear-input", () => {
        this.textarea.value = ""
        this.resize()
        this.textarea.focus()
      })
    },
    resize() {
      if (!this.textarea) return
      this.textarea.style.height = "auto"
      this.textarea.style.height = Math.min(this.textarea.scrollHeight, 200) + "px"
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
