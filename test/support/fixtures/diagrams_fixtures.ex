defmodule Diogramos.DiagramsFixtures do
  @moduledoc """
  Test helpers for creating diagram entities (folders, canvases, etc).
  """

  alias Diogramos.Accounts.Scope
  alias Diogramos.Diagrams

  def folder_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "folder-#{System.unique_integer([:positive])}"})
    {:ok, folder} = Diagrams.create_folder(scope, attrs)
    folder
  end

  def canvas_fixture(%Scope{} = scope, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        slug: "canvas-#{n}",
        title: "Canvas #{n}",
        theme: "afterdark"
      })

    {:ok, canvas} = Diagrams.create_canvas(scope, attrs)
    canvas
  end
end
