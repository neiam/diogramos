defmodule DiogramosWeb.PageController do
  use DiogramosWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
