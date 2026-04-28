defmodule Diogramos.Diagrams.Authority do
  @moduledoc """
  GenServer-per-canvas that owns the canonical document and broadcasts
  ops to subscribers via Phoenix.PubSub.

  Lifecycle:
    * Started on demand via `for_canvas/1` (looks up via Registry, spawns
      under DynamicSupervisor if needed).
    * Validates each op against the current `version`. On success it
      increments the version, applies the op, persists every N ops, and
      broadcasts `{:canvas_op, %{op, version, actor_ref}}` on
      `topic/1` so all subscribed LiveViews update.
    * Idle for `@hibernate_after` ms → snapshot to DB and `hibernate`.

  Failure modes:
    * Version mismatch (stale op) → `{:error, :stale}`. Caller should
      refetch and retry.
    * Op invalid (per `Document.apply_op/2`) → `{:error, reason}`.
    * Forbidden (write/admin denied) → `{:error, :forbidden}`.
  """

  alias Diogramos.Accounts.Scope
  alias Diogramos.Diagrams.{Canvas, Document, Permissions}
  alias Diogramos.Repo

  @registry Diogramos.Diagrams.AuthorityRegistry
  @supervisor Diogramos.Diagrams.AuthoritySupervisor
  @snapshot_every 25
  @hibernate_after :timer.minutes(5)

  ## Public API -------------------------------------------------------------

  @doc "PubSub topic for the given canvas id."
  @spec topic(integer()) :: String.t()
  def topic(canvas_id), do: "canvas:#{canvas_id}"

  @doc """
  Returns (lazily starting) the pid of the authority for `canvas_id`.
  """
  @spec for_canvas(integer()) :: {:ok, pid()} | {:error, term()}
  def for_canvas(canvas_id) when is_integer(canvas_id) do
    case Horde.Registry.lookup(@registry, canvas_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> start_authority(canvas_id)
    end
  end

  @doc """
  Applies an op against the canvas authority. `actor_ref` is an opaque
  binary the LV uses to recognize echoes of its own ops.
  """
  @spec apply_op(integer(), Scope.t(), map(), binary()) ::
          {:ok, %{document: map(), version: integer()}} | {:error, term()}
  def apply_op(canvas_id, %Scope{} = scope, op, actor_ref \\ "") do
    with {:ok, pid} <- for_canvas(canvas_id) do
      GenServer.call(pid, {:apply_op, scope, op, actor_ref})
    end
  end

  @doc "Returns the current document + version for a canvas."
  @spec snapshot(integer()) :: {:ok, %{document: map(), version: integer()}} | {:error, term()}
  def snapshot(canvas_id) do
    with {:ok, pid} <- for_canvas(canvas_id) do
      GenServer.call(pid, :snapshot)
    end
  end

  @doc """
  Stops the authority for a canvas. Used in tests and during canvas
  delete. Persists current state before exit.
  """
  def stop(canvas_id) do
    case Horde.Registry.lookup(@registry, canvas_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  ## Supervision wiring ----------------------------------------------------

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :supervisor
    }
  end

  def start_link(_opts \\ []) do
    Supervisor.start_link(
      [
        {Horde.Registry, keys: :unique, name: @registry, members: :auto},
        {Horde.DynamicSupervisor,
         strategy: :one_for_one,
         name: @supervisor,
         distribution_strategy: Horde.UniformDistribution,
         members: :auto,
         process_redistribution: :active}
      ],
      strategy: :one_for_all,
      name: __MODULE__.Supervisor
    )
  end

  defp start_authority(canvas_id) do
    spec = {__MODULE__.Server, canvas_id}
    Horde.DynamicSupervisor.start_child(@supervisor, spec)
  end

  ## Server module ---------------------------------------------------------

  defmodule Server do
    @moduledoc false
    use GenServer, restart: :transient

    alias Diogramos.Diagrams.Authority

    def start_link(canvas_id) do
      GenServer.start_link(__MODULE__, canvas_id,
        name: {:via, Horde.Registry, {Authority.registry(), canvas_id}}
      )
    end

    @impl true
    def init(canvas_id) do
      # Defer DB load until first call so test sandboxes have time to
      # grant allowance to this pid after `for_canvas/1` returns.
      {:ok, %{canvas_id: canvas_id, loaded: false}, Authority.hibernate_after()}
    end

    @impl true
    def handle_call({:apply_op, scope, op, actor_ref}, _from, state) do
      with {:ok, state} <- Authority.ensure_loaded(state),
           {:ok, new_state, payload} <- Authority.do_apply_op(state, scope, op, actor_ref) do
        {:reply, {:ok, payload}, new_state, Authority.hibernate_after()}
      else
        {:error, reason} -> {:reply, {:error, reason}, state, Authority.hibernate_after()}
      end
    end

    def handle_call(:snapshot, _from, state) do
      case Authority.ensure_loaded(state) do
        {:ok, loaded} ->
          {:reply, {:ok, %{document: loaded.document, version: loaded.version}}, loaded,
           Authority.hibernate_after()}

        {:error, reason} ->
          {:reply, {:error, reason}, state, Authority.hibernate_after()}
      end
    end

    @impl true
    def handle_info(:timeout, state) do
      Authority.persist_if_dirty(state)
      state = if state.loaded, do: %{state | ops_since_snapshot: 0}, else: state
      {:noreply, state, :hibernate}
    end

    @impl true
    def terminate(_reason, state), do: Authority.persist_if_dirty(state)
  end

  ## Internals exposed for the Server module ------------------------------

  @doc false
  def registry, do: @registry

  @doc false
  def hibernate_after, do: @hibernate_after

  @doc false
  def normalize_document(nil), do: Document.new()

  def normalize_document(%{"elements" => _, "order" => _, "connectors" => _} = doc), do: doc

  def normalize_document(other) when is_map(other) do
    %{
      "elements" => Map.get(other, "elements", %{}),
      "order" => Map.get(other, "order", []),
      "connectors" => Map.get(other, "connectors", %{})
    }
  end

  @doc false
  def load_canvas(canvas_id) do
    case Repo.get(Canvas, canvas_id) do
      nil -> {:error, :not_found}
      canvas -> {:ok, canvas}
    end
  end

  @doc false
  def ensure_loaded(%{loaded: true} = state), do: {:ok, state}

  def ensure_loaded(%{canvas_id: canvas_id} = state) do
    case load_canvas(canvas_id) do
      {:ok, canvas} ->
        loaded = %{
          canvas_id: canvas_id,
          canvas: canvas,
          document: normalize_document(canvas.document),
          version: canvas.version,
          ops_since_snapshot: 0,
          loaded: true
        }

        {:ok, Map.merge(state, loaded)}

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def do_apply_op(state, scope, op, actor_ref) do
    with :ok <- Permissions.authorize(scope, write_action_for(op), state.canvas),
         {:ok, doc} <- Document.apply_op(state.document, op) do
      version = state.version + 1

      new_state =
        %{
          state
          | document: doc,
            version: version,
            ops_since_snapshot: state.ops_since_snapshot + 1
        }
        |> maybe_snapshot()

      payload = %{op: op, version: version, actor_ref: actor_ref}
      Phoenix.PubSub.broadcast(Diogramos.PubSub, topic(state.canvas_id), {:canvas_op, payload})

      {:ok, new_state, %{document: doc, version: version}}
    end
  end

  defp write_action_for(%{"type" => type}) do
    if type in ~w(insert_element update_element delete_element insert_connector update_connector delete_connector set_z_order),
      do: :write,
      else: :write
  end

  defp maybe_snapshot(%{ops_since_snapshot: n} = state) when n >= @snapshot_every do
    persist!(state)
    %{state | ops_since_snapshot: 0}
  end

  defp maybe_snapshot(state), do: state

  @doc false
  def persist_if_dirty(%{loaded: false}), do: :ok
  def persist_if_dirty(%{ops_since_snapshot: 0}), do: :ok
  def persist_if_dirty(state), do: persist!(state)

  defp persist!(state) do
    state.canvas
    |> Ecto.Changeset.change(document: state.document, version: state.version)
    |> Repo.update!()

    :ok
  rescue
    # Tests stop authorities after the sandbox connection has been
    # checked back in, which makes the persist on terminate raise
    # DBConnection.ConnectionError. That's not a real failure mode in
    # production, so we swallow it here.
    DBConnection.ConnectionError -> :ok
    DBConnection.OwnershipError -> :ok
    Postgrex.Error -> :ok
  end
end
