defmodule NaturecountsWeb.NavHook do
  @moduledoc false
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :set_current_path, :handle_params, &set_current_path/3)}
  end

  defp set_current_path(_params, uri, socket) do
    path = URI.parse(uri).path
    {:cont, assign(socket, :current_path, path)}
  end
end
