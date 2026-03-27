const CropZoom = {
  mounted() {
    const img = this.el.querySelector("img")
    if (!img) return

    this.el.addEventListener("click", () => {
      // Create modal overlay
      const overlay = document.createElement("div")
      Object.assign(overlay.style, {
        position: "fixed",
        inset: "0",
        zIndex: "1000",
        backgroundColor: "rgba(0,0,0,0.8)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        cursor: "pointer",
        opacity: "0",
        transition: "opacity 150ms ease-out",
      })

      const zoomed = img.cloneNode(true)
      zoomed.className = ""
      Object.assign(zoomed.style, {
        maxWidth: "90vw",
        maxHeight: "90vh",
        objectFit: "contain",
        borderRadius: "0.5rem",
        boxShadow: "0 25px 50px -12px rgba(0,0,0,0.5)",
      })

      overlay.appendChild(zoomed)
      document.body.appendChild(overlay)

      // Close on click or Escape
      const close = () => {
        overlay.style.opacity = "0"
        setTimeout(() => overlay.remove(), 150)
      }
      overlay.addEventListener("click", close)
      const onKey = (e) => {
        if (e.key === "Escape") {
          close()
          document.removeEventListener("keydown", onKey)
        }
      }
      document.addEventListener("keydown", onKey)

      requestAnimationFrame(() => { overlay.style.opacity = "1" })
    })
  },
}

export default CropZoom
