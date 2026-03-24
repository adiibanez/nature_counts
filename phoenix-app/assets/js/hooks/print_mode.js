const PrintMode = {
  mounted() {
    // Wait for images to load before enabling print
    const images = this.el.querySelectorAll("img")
    if (images.length === 0) return

    let loaded = 0
    const total = images.length
    const checkReady = () => {
      loaded++
      if (loaded >= total) {
        this.el.dataset.imagesLoaded = "true"
      }
    }

    images.forEach(img => {
      if (img.complete) {
        checkReady()
      } else {
        img.addEventListener("load", checkReady)
        img.addEventListener("error", checkReady)
      }
    })
  }
}

export default PrintMode
