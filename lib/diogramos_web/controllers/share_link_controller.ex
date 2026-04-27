defmodule DiogramosWeb.ShareLinkController do
  use DiogramosWeb, :controller

  alias Diogramos.Diagrams
  alias Diogramos.Diagrams.{Canvas, Folder}
  alias DiogramosWeb.UserAuth

  def show(conn, %{"token" => token}) do
    current_user = current_user(conn)

    case Diagrams.redeem_share_link(token, current_user) do
      {:ok, user, subject} ->
        conn
        |> put_session(:user_return_to, redirect_path_for(subject))
        |> maybe_log_in(user, current_user)

      {:error, :invalid_link} ->
        conn
        |> put_flash(:error, "That share link is invalid, expired, or has been revoked.")
        |> redirect(to: ~p"/")

      {:error, :subject_missing} ->
        conn
        |> put_flash(:error, "The shared resource no longer exists.")
        |> redirect(to: ~p"/")

      {:error, _} ->
        conn
        |> put_flash(:error, "We couldn't redeem that share link.")
        |> redirect(to: ~p"/")
    end
  end

  defp current_user(conn) do
    case conn.assigns[:current_scope] do
      %{user: user} -> user
      _ -> nil
    end
  end

  defp maybe_log_in(conn, _user, %{} = _existing_user),
    do: redirect(conn, to: get_session(conn, :user_return_to))

  defp maybe_log_in(conn, user, nil), do: UserAuth.log_in_user(conn, user)

  # Routes for /c/:slug and /folders/:id are introduced in Phase 3.
  # Until they exist we hand back unverified path strings so the controller
  # compiles cleanly; these are normalized to the editor route once added.
  defp redirect_path_for(%Canvas{slug: slug}), do: "/c/" <> slug
  defp redirect_path_for(%Folder{id: id}), do: "/folders/" <> Integer.to_string(id)
end
