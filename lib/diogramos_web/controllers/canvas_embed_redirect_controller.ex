defmodule DiogramosWeb.CanvasEmbedRedirectController do
  @moduledoc """
  Resolves a canvas slug to its public embed URL.

  Used by metadata `link` icons whose `kind` is `"canvas"`. The icon's
  href is `/c-embed/<slug>`; this controller looks up the canvas and
  redirects to `/embed/<embed_token>` if embedding is enabled. If the
  canvas is missing or its embed is disabled, the visitor sees a plain
  404 — we deliberately don't reveal whether the slug exists.
  """
  use DiogramosWeb, :controller

  alias Diogramos.Repo
  alias Diogramos.Diagrams.Canvas

  def show(conn, %{"slug" => slug}) when is_binary(slug) do
    case Repo.get_by(Canvas, slug: slug) do
      %Canvas{embed_token: token} when is_binary(token) and token != "" ->
        redirect(conn, to: ~p"/embed/#{token}")

      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(html: DiogramosWeb.ErrorHTML, json: DiogramosWeb.ErrorJSON)
        |> render(:"404")
    end
  end
end
