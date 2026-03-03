import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// Hook pour déclencher le téléchargement d'un fichier JSON depuis le serveur
let Hooks = {}

Hooks.DownloadJson = {
  mounted() {
    this.handleEvent("download_json", ({filename, content}) => {
      const blob = new Blob([content], {type: "application/json"})
      const url  = URL.createObjectURL(blob)
      const a    = document.createElement("a")
      a.href     = url
      a.download = filename
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)
    })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()
window.liveSocket = liveSocket
