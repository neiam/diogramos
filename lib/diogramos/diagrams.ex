defmodule Diogramos.Diagrams do
  @moduledoc """
  Public boundary for the diagramming domain.

  Delegates to focused sub-modules:

    * `Diogramos.Diagrams.Folders` — folder CRUD
    * `Diogramos.Diagrams.Permissions` — role resolution + grants
    * `Diogramos.Diagrams.Canvases` — (later) canvas CRUD
    * `Diogramos.Diagrams.ShareLinks` — (later) share-link redemption
  """

  alias Diogramos.Diagrams.{Canvases, Folders, Permissions, ShareLinks}

  ## Share links ------------------------------------------------------------

  defdelegate create_share_link(scope, subject, role, opts \\ []), to: ShareLinks, as: :create
  defdelegate get_active_share_link(token), to: ShareLinks, as: :get_active_by_token
  defdelegate list_share_links_for(subject), to: ShareLinks, as: :list_for
  defdelegate revoke_share_link(scope, link), to: ShareLinks, as: :revoke
  defdelegate redeem_share_link(token, current_user), to: ShareLinks, as: :redeem

  ## Canvases ---------------------------------------------------------------

  defdelegate list_canvases(scope), to: Canvases, as: :list
  defdelegate list_canvases_in_folder(scope, folder_id), to: Canvases, as: :list_in_folder
  defdelegate get_canvas!(scope, id), to: Canvases, as: :get!
  defdelegate get_canvas_by_slug(scope, slug), to: Canvases, as: :get_by_slug
  defdelegate get_canvas_for_embed(token), to: Canvases, as: :get_for_embed
  defdelegate create_canvas(scope, attrs), to: Canvases, as: :create
  defdelegate update_canvas_metadata(scope, canvas, attrs), to: Canvases, as: :update_metadata
  defdelegate delete_canvas(scope, canvas), to: Canvases, as: :delete
  defdelegate set_canvas_embed_token(scope, canvas, token), to: Canvases, as: :set_embed_token
  defdelegate generate_canvas_embed_token(scope, canvas), to: Canvases, as: :generate_embed_token

  defdelegate replace_canvas_document(scope, canvas, document),
    to: Canvases,
    as: :replace_document

  defdelegate export_canvas(scope, canvas), to: Canvases, as: :export
  defdelegate import_canvas(scope, data, opts \\ []), to: Canvases, as: :import_canvas

  ## Folders ----------------------------------------------------------------

  defdelegate list_folders(scope), to: Folders, as: :list
  defdelegate get_folder!(scope, id), to: Folders, as: :get!
  defdelegate create_folder(scope, attrs), to: Folders, as: :create
  defdelegate rename_folder(scope, folder, new_name), to: Folders, as: :rename
  defdelegate move_folder(scope, folder, new_parent_id), to: Folders, as: :move
  defdelegate delete_folder(scope, folder), to: Folders, as: :delete

  ## Permissions ------------------------------------------------------------

  defdelegate effective_role(scope, resource), to: Permissions
  defdelegate authorize(scope, action, resource), to: Permissions

  defdelegate grant_permission(s_type, s_id, p_type, p_id, role, opts \\ []),
    to: Permissions,
    as: :grant

  defdelegate revoke_permission(s_type, s_id, p_type, p_id), to: Permissions, as: :revoke
  defdelegate list_user_grants(subject_type, subject_id), to: Permissions
end
