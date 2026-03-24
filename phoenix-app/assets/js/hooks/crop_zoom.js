const CropZoom = {
  mounted() {
    const img = this.el.querySelector("img")
    if (!img) return

    let zoomed = null

    this.el.addEventListener("mouseenter", () => {
      const rect = img.getBoundingClientRect()

      zoomed = img.cloneNode(true)
      zoomed.className = ""
      Object.assign(zoomed.style, {
        position: "fixed",
        left: `${rect.left + rect.width / 2}px`,
        top: `${rect.top + rect.height / 2}px`,
        transform: "translate(-50%, -50%)",
        width: `${rect.width * 3}px`,
        height: `${rect.height * 3}px`,
        objectFit: "contain",
        zIndex: "100",
        pointerEvents: "none",
        borderRadius: "0.5rem",
        boxShadow: "0 25px 50px -12px rgba(0,0,0,0.5)",
        transition: "opacity 150ms ease-out",
        opacity: "0",
      })
      document.body.appendChild(zoomed)
      // trigger transition
      requestAnimationFrame(() => { if (zoomed) zoomed.style.opacity = "1" })
    })

    this.el.addEventListener("mouseleave", () => {
      if (zoomed) {
        zoomed.remove()
        zoomed = null
      }
    })
  },
}

export default CropZoom
