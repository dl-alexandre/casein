// SpeechInput hook
//
// A push-to-talk mic button that dictates into the focused terminal pane using
// the browser's Web Speech API (webkitSpeechRecognition). Audio capture and
// transcription happen entirely in the browser — there is NO dev_ide backend
// involved. Final transcripts are written into the active terminal input via
// the shared injectTerminalText() path, exactly as if the user had typed them.
// We never auto-send Enter: the user reviews the dictated text and submits it.
//
// Note: in Chrome/Edge the Web Speech API streams audio to the browser vendor's
// servers for recognition. "No backend" means no dev_ide server, not fully
// on-device. Firefox does not implement it — the button hides itself there.
import { injectTerminalText } from "./terminal_inject"

const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition

export const SpeechInput = {
  mounted() {
    // Feature-detect. Unsupported browsers (e.g. Firefox) get no mic button.
    if (!SpeechRecognition) {
      this.el.hidden = true
      this.el.setAttribute("aria-hidden", "true")
      this.el.title = "Voice input is not supported in this browser"
      return
    }

    this.listening = false
    this.userStopped = false

    this.recognition = new SpeechRecognition()
    this.recognition.continuous = true
    this.recognition.interimResults = true
    this.recognition.lang = navigator.language || "en-US"

    this.recognition.onresult = (event) => {
      // Inject only finalized segments; interim results would flood the PTY
      // with churn that gets retracted.
      let final = ""
      for (let i = event.resultIndex; i < event.results.length; i++) {
        const result = event.results[i]
        if (result.isFinal) final += result[0].transcript
      }
      if (final.trim()) injectTerminalText(final.replace(/\s+$/, "") + " ")
    }

    this.recognition.onerror = (event) => {
      if (event.error === "not-allowed" || event.error === "service-not-allowed") {
        // Mic permission denied / blocked — stop and surface why.
        this.userStopped = true
        this.el.title = "Microphone access blocked — allow it in site settings"
        this._setListening(false)
      } else if (event.error === "no-speech" || event.error === "aborted") {
        // Transient: onend will restart if the user is still listening.
      } else {
        console.warn("speech recognition error", event.error)
      }
    }

    this.recognition.onend = () => {
      // Chrome ends the session after a silence window even in continuous mode.
      // Restart transparently so the mic stays "on" until the user toggles off.
      if (this.listening && !this.userStopped) {
        try {
          this.recognition.start()
          return
        } catch (_) {
          // start() throws if a session is already pending — fall through.
        }
      }
      this._setListening(false)
    }

    this.onClick = () => this._toggle()
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    if (this.recognition) {
      this.userStopped = true
      try { this.recognition.stop() } catch (_) {}
      this.recognition.onresult = this.recognition.onend = this.recognition.onerror = null
    }
  },

  _toggle() {
    if (this.listening) {
      this.userStopped = true
      try { this.recognition.stop() } catch (_) {}
      this._setListening(false)
      return
    }

    this.userStopped = false
    try {
      this.recognition.start()
      this._setListening(true)
    } catch (_) {
      // start() throws if called while a prior session is still tearing down.
      this._setListening(false)
    }
  },

  _setListening(on) {
    this.listening = on
    this.el.dataset.listening = on ? "true" : "false"
    this.el.setAttribute("aria-pressed", on ? "true" : "false")
  }
}
