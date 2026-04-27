defmodule DiogramosWeb.CanvasExportController do
  @moduledoc """
  Streams a canvas as JSON for download. Visible to anyone with read
  access to the canvas (per the standard scope). The exported file is a
  valid input for `Diogramos.Diagrams.import_canvas/3`.
  """
  use DiogramosWeb, :controller

  alias Diogramos.Diagrams

  def show(conn, %{"slug" => slug}) do
    scope = conn.assigns.current_scope

    case Diagrams.get_canvas_by_slug(scope, slug) do
      nil ->
        conn |> put_status(:not_found) |> put_view(html: DiogramosWeb.ErrorHTML) |> render(:"404")

      canvas ->
        case Diagrams.export_canvas(scope, canvas) do
          {:ok, payload} ->
            json = Jason.encode!(payload, pretty: true)
            filename = "#{canvas.slug}.json"

            conn
            |> put_resp_content_type("application/json")
            |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
            |> send_resp(200, json)

          {:error, :forbidden} ->
            conn
            |> put_status(:forbidden)
            |> put_view(html: DiogramosWeb.ErrorHTML)
            |> render(:"403")
        end
    end
  end
end
