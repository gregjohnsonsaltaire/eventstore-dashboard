defmodule EventStore.Dashboard.Components.EventsTable do
  alias EventStore.Streams.StreamInfo
  alias Phoenix.LiveDashboard.PageBuilder
  import Phoenix.Component
  import EventStore.Dashboard.Helpers
  import Phoenix.LiveDashboard.PageBuilder

  def render(assigns) do
    %{page: %{params: params}} = assigns

    event_number = parse_event_number(params)
    assigns = assign(assigns, event_number: event_number, stream_uuid: parse_stream_uuid(params))

    ~H"""
    <%= if @event_number do %>
      <.event_modal
        event_number={@event_number}
        event_store={@event_store}
        page={@page}
        socket={@socket}
        stream_uuid={@stream_uuid}
      />
    <% else %>
      <.events event_store={@event_store} page={@page} stream_uuid={@stream_uuid} />
    <% end %>
    """
  end

  defp parse_stream_uuid(params) do
    case Map.get(params, "stream") do
      "" -> "$all"
      stream when is_binary(stream) -> stream
      nil -> "$all"
    end
  end

  defp parse_event_number(params) do
    case Map.get(params, "event") do
      "" -> nil
      event when is_binary(event) -> String.to_integer(event)
      nil -> nil
    end
  end

  defp event_modal(assigns) do
    %{page: %{params: params}} = assigns
    params = Map.put(params, "event", nil)

    return_to =
      PageBuilder.live_dashboard_path(
        assigns.socket,
        assigns.page.route,
        assigns.page.node,
        params,
        Enum.into([], params)
      )

    assigns = assign(assigns, :return_to, return_to)

    ~H"""
    <PageBuilder.live_modal id="event_modal" title="Event" return_to={@return_to}>
      <.live_component
        event_store={@event_store}
        event_number={@event_number}
        id="event_modal_body"
        module={EventStore.Dashboard.Components.EventModal}
        node={@page.node}
        page={@page}
        return_to={@return_to}
        stream_uuid={@stream_uuid}
      />
    </PageBuilder.live_modal>
    """
  end

  defp events(assigns) do
    title =
      if assigns.stream_uuid == "$all",
        do: "All stream events",
        else: "Stream #{inspect(assigns.stream_uuid)} events"

    assigns = assign(assigns, title: title)

    ~H"""
    <.live_table
      id="events-table"
      dom_id="events-table"
      page={@page}
      title={@title}
      rows_name="events"
      row_fetcher={&read_stream(@event_store, @stream_uuid, &1, &2)}
      row_attrs={&row_attrs(&1, @stream_uuid)}
      search={false}
      default_sort_by={:event_number}
    >
      <:col
        field={:event_number}
        header="Event #"
        cell_attrs={[class: "tabular-column-name pl-4"]}
        sortable={:desc}
      />
      <:col
        field={:event_id}
        header="Event id"
        header_attrs={[class: "pl-4"]}
        cell_attrs={[class: "tabular-column-id pl-4"]}
      />
      <:col field={:event_type} header="Event type" />
      <:col
        :for={col <- extra_columns(@stream_uuid)}
        field={col[:field]}
        header={col[:header]}
        cell_attrs={col[:cell_attrs]}
      />
      <:col field={:created_at} header="Created at" />
    </.live_table>
    """
  end

  defp read_stream(event_store, stream_uuid, params, node) do
    with {:ok, %StreamInfo{} = stream} <- stream_info(node, event_store, stream_uuid),
         {:ok, recorded_events} <- recorded_events(node, event_store, stream_uuid, params) do
      %StreamInfo{stream_version: stream_version} = stream

      entries = Enum.map(recorded_events, &Map.from_struct/1)
      {entries, stream_version}
    else
      {:error, _error} -> {[], 0}
    end
  end

  defp stream_info(node, event_store, stream_uuid) do
    rpc_event_store(node, event_store, :stream_info, [stream_uuid])
  end

  defp recorded_events(node, event_store, stream_uuid, params) do
    %{sort_by: _sort_by, sort_dir: sort_dir, limit: limit} = params

    {read_stream_function, start_version} =
      case sort_dir do
        :asc -> {:read_stream_forward, 0}
        :desc -> {:read_stream_backward, -1}
      end

    rpc_event_store(node, event_store, read_stream_function, [stream_uuid, start_version, limit])
  end

  defp extra_columns("$all") do
    [
      %{
        field: :stream_uuid,
        header: "Source stream",
        cell_attrs: [class: "tabular-column-name pl-4"]
      },
      %{
        field: :stream_version,
        header: "Source version"
      }
    ]
  end

  defp extra_columns(_), do: []

  defp row_attrs(table, stream_uuid) do
    [
      {"phx-click", "show_event"},
      {"phx-value-stream", stream_uuid},
      {"phx-value-event", table[:event_number]},
      {"phx-page-loading", true}
    ]
  end
end
