defmodule TimelessCanvas.Canvas.VariableResolver do
  @moduledoc """
  Resolves `$varname` references in element meta and labels using variable bindings.

  Whole-value matching only — `"$host"` resolves but `"prefix-$host"` does not.
  """

  alias TimelessCanvas.Canvas.Element

  @doc """
  Build a bindings map from canvas variables: `%{"host" => "prod-1.example.com"}`.
  """
  def bindings(variables) when is_map(variables) do
    Map.new(variables, fn {name, definition} -> {name, definition["current"] || ""} end)
  end

  @doc """
  Resolve all elements in a map using the given bindings.
  """
  def resolve_elements(elements, bindings) when is_map(elements) and is_map(bindings) do
    Map.new(elements, fn {id, el} -> {id, resolve_element(el, bindings)} end)
  end

  @doc """
  Resolve a single element's meta values and label.
  """
  def resolve_element(%Element{} = element, bindings) when is_map(bindings) do
    resolved_meta = Map.new(element.meta, fn {k, v} -> {k, resolve_value(v, bindings)} end)
    resolved_label = resolve_value(element.label, bindings)
    %{element | meta: resolved_meta, label: resolved_label}
  end

  defp resolve_value("$" <> var_name, bindings) do
    Map.get(bindings, var_name, "$" <> var_name)
  end

  defp resolve_value(value, _bindings), do: value
end
