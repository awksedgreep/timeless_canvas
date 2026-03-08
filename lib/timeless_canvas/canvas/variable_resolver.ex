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
    meta_with_pins = apply_pins(element.pins, bindings, element.meta)
    resolved_meta = Map.new(meta_with_pins, fn {k, v} -> {k, resolve_value(v, bindings)} end)
    resolved_label = resolve_value(element.label, bindings)
    %{element | meta: resolved_meta, label: resolved_label}
  end

  defp resolve_value("$" <> var_name, bindings) do
    Map.get(bindings, var_name, "$" <> var_name)
  end

  defp resolve_value(value, _bindings), do: value

  defp apply_pins(pins, bindings, meta) do
    Enum.reduce(Element.pin_dimensions(), meta, fn dim_atom, acc ->
      dim = Atom.to_string(dim_atom)

      case Map.get(pins, dim) do
        nil ->
          acc

        %{"mode" => "none"} ->
          acc

        %{"mode" => "literal", "value" => val} when val != "" ->
          Map.put(acc, dim, val)

        %{"mode" => "variable", "value" => var} when var != "" ->
          var_name = String.replace_leading(var, "$", "")
          resolved = Map.get(bindings, var_name, "$#{var_name}")
          Map.put(acc, dim, resolved)

        _ ->
          acc
      end
    end)
  end
end
