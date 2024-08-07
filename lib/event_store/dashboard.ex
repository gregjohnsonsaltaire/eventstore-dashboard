defmodule EventStore.Dashboard do
  alias Phoenix.LiveDashboard.PageBuilder
  alias EventStore.Dashboard.Components.{EventsTable, StreamsTable}

  use PageBuilder, refresher?: false

  # Minimum supported EventStore version that can be used on remote nodes.
  @minimum_event_store_version "1.4.0"

  @disabled_link "https://hexdocs.pm/eventstore_dashboard"
  @page_title "Event Stores"

  @impl PageBuilder
  def init(opts) do
    event_stores = opts[:event_stores] || :auto_discover

    {:ok, %{event_stores: event_stores}, application: :eventstore}
  end

  @impl PageBuilder
  def menu_link(%{event_stores: event_stores}, _capabilities) do
    if event_stores == [],
      do: {:disabled, @page_title, @disabled_link},
      else: {:ok, @page_title}
  end

  @impl PageBuilder
  def mount(params, %{event_stores: event_stores}, socket) do
    case event_stores_or_auto_discover(event_stores, socket.assigns.page.node) do
      {:ok, event_stores} ->
        socket = assign(socket, :event_stores, Enum.sort(event_stores))
        event_store = nav_event_store(params, event_stores)

        if event_store do
          node = socket.assigns.page.node

          with :ok <- check_socket_connection(socket),
               :ok <- check_event_store_version(node) do
            {:ok, assign(socket, event_store: event_store)}
          else
            {:error, error} ->
              {:ok, assign(socket, event_store: nil, stream: nil, event: nil, error: error)}
          end
        else
          {event_store, _opts} = hd(event_stores)

          to = live_dashboard_path(socket, socket.assigns.page, eventstore: inspect(event_store))

          {:ok, push_navigate(socket, to: to)}
        end

      {:error, error} ->
        {:ok, assign(socket, event_store: nil, stream: nil, event: nil, error: error)}
    end
  end

  @impl PageBuilder
  def handle_event("show_stream", %{"stream" => stream_uuid}, socket) do
    %{page: page} = socket.assigns
    stream_uuid = if stream_uuid == "$all", do: nil, else: stream_uuid

    to =
      live_dashboard_path(socket, page,
        nav: "events",
        stream: stream_uuid,
        event: nil
      )

    {:noreply, push_patch(socket, to: to)}
  end

  @impl PageBuilder
  def handle_event("show_event", %{"event" => event, "stream" => stream}, socket) do
    %{page: page} = socket.assigns

    stream_uuid = if stream == "$all", do: nil, else: stream
    event_number = String.to_integer(event)

    to =
      live_dashboard_path(socket, page,
        nav: "events",
        stream: stream_uuid,
        event: event_number
      )

    {:noreply, push_patch(socket, to: to)}
  end

  @impl PageBuilder
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl PageBuilder
  def render(assigns) do
    if assigns[:error] do
      render_error(assigns)
    else
      ~H"""
      <.live_nav_bar
        extra_params={[:nav]}
        id="event-store-dashboard"
        nav_param="eventstore"
        page={@page}
        style={:bar}
      >
        <:item
          :for={{module, _} = event_store <- @event_stores}
          label={inspect(module)}
          name={inspect(module)}
          method="patch"
        >
          <.render_event_store_tab event_store={event_store} page={@page} socket={@socket} />
        </:item>
      </.live_nav_bar>
      """
    end
  end

  defp event_stores_or_auto_discover(event_store_config, node) do
    cond do
      event_store_config == [] ->
        {:error, :no_event_stores_available}

      is_list(event_store_config) ->
        event_stores =
          Enum.map(event_store_config, fn
            {event_store, opts} when is_atom(event_store) and is_list(opts) ->
              {event_store, opts}

            event_store when is_atom(event_store) ->
              {event_store, name: event_store}

            invalid ->
              raise ArgumentError, message: "Invalid event store config: " <> inspect(invalid)
          end)

        {:ok, event_stores}

      event_store_config == :auto_discover ->
        with :ok <- check_event_store_version(node) do
          running_event_stores(node)
        end

      true ->
        {:error, :no_event_stores_available}
    end
  end

  defp running_event_stores(node) do
    case :rpc.call(node, EventStore, :all_instances, []) do
      [] ->
        {:error, :no_event_stores_available}

      event_stores when is_list(event_stores) ->
        {:ok, event_stores}

      {:badrpc, _error} ->
        {:error, :cannot_list_running_event_stores}
    end
  end

  defp nav_event_store(params, event_stores) do
    eventstore = Map.get(params, "eventstore")

    if eventstore && eventstore != "" do
      Enum.find(event_stores, fn {module, _opts} -> inspect(module) == eventstore end)
    end
  end

  defp check_socket_connection(socket) do
    if connected?(socket) do
      :ok
    else
      {:error, :connection_is_not_available}
    end
  end

  defp render_event_store_tab(assigns) do
    if assigns[:error] do
      render_error(assigns)
    else
      items = [
        %{name: "streams", module: StreamsTable, event_store: assigns.event_store},
        %{name: "events", module: EventsTable, event_store: assigns.event_store}
        # %{name: "event", module: EventInfo}
        # TODO: Subscriptions, snapshots --%>
      ]

      assigns = assign(assigns, items: items)

      ~H"""
      <.live_nav_bar
        extra_params={[:eventstore]}
        id="event_store_tab"
        nav_param="nav"
        page={@page}
        style={:pills}
      >
        # can't work out why, but if {assigns} is not included __changed__ is set to nil
        # and StreamsTable/EventsTable don't render on change of event_store
        <:item name="streams">
          <StreamsTable.render event_store={@event_store} page={@page} {assigns} />
        </:item>
        <:item name="events">
          <EventsTable.render event_store={@event_store} page={@page} {assigns} />
        </:item>
        <%!--
        <:item name="event">
          <EventInfo.render event_store={@event_store} page={@page} {assigns} />
        </:item>
        # TODO: Subscriptions, snapshots
        --%>
      </.live_nav_bar>
      """
    end
  end

  defp render_error(assigns) do
    msg =
      case assigns.error do
        :connection_is_not_available ->
          "Dashboard is not connected yet."

        :event_store_not_found ->
          "This event store is not available for this node."

        :event_store_is_not_running ->
          "This event store is not running on this node."

        :event_store_is_not_available ->
          "EventStore is not available on remote node."

        :version_is_not_enough ->
          "EventStore is outdated on remote node. Minimum version required is #{@minimum_event_store_version}"

        :no_event_stores_available ->
          "There is no event store running on this node."

        :cannot_list_running_event_stores ->
          "Could not list running event stores at remote node. Please try again later."

        :not_able_to_start_remotely ->
          "Could not start the metrics server remotely. Please try again later."

        {:badrpc, _} ->
          "Could not send request to node. Try again later."
      end

    assigns = assign(assigns, :msg, msg)

    ~H"""
    <.row>
      <:col><%= @msg %></:col>
    </.row>
    """
  end

  defp check_event_store_version(node) do
    case :rpc.call(node, Application, :spec, [:eventstore, :vsn]) do
      {:badrpc, _reason} = error ->
        {:error, error}

      vsn when is_list(vsn) ->
        if Version.compare(to_string(vsn), @minimum_event_store_version) in [:gt, :eq] do
          :ok
        else
          {:error, :version_is_not_enough}
        end

      nil ->
        {:error, :event_store_is_not_available}
    end
  end
end
