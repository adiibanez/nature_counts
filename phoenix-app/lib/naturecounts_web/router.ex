defmodule NaturecountsWeb.Router do
  use NaturecountsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NaturecountsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  get "/health", NaturecountsWeb.HealthController, :index

  # Serve VLM crop debug images
  scope "/debug/crops", NaturecountsWeb do
    get "/:filename", CropsController, :show
  end

  # Serve video files for preview playback
  scope "/serve/videos", NaturecountsWeb do
    get "/*path", VideoController, :show
  end

  # Redirect to GCS signed URL for cloud video playback
  scope "/serve/gcs", NaturecountsWeb do
    get "/*path", VideoController, :show_gcs
  end

  scope "/", NaturecountsWeb do
    pipe_through :browser

    live_session :default, layout: {NaturecountsWeb.Layouts, :app} do
      live "/", DashboardLive
      live "/camera/:id", CameraLive
      live "/videos", VideosLive
      live "/inventory", InventoryLive
      live "/crops", CropsLive
    end
  end

  # HLS proxy — in production, use nginx/reverse proxy instead.
  # For dev, the browser fetches HLS from MediaMTX directly at :8888.
end
