defmodule Casein.Terminals.SessionOwner.ResponseClassifier do
  @moduledoc false

  @cpr_response ~r/\A\e\[\??\d+;\d+R/
  @da_response ~r/\A\e\[(?:\?|>)[0-9;]*c/
  @decrpm_response ~r/\A\e\[\?[0-9;]*\$y/
  @kitty_response ~r/\A\e\[\?[0-9;]*u/
  @osc_color_response ~r/\A\e\](?:10|11|12);/
  @osc_palette_response ~r/\A\e\]4;/
  @xtversion_response ~r/\A\eP>\|/
  @theme_report_response ~r/\A\e\[\?997;[12]n/

  def classify_query_response(data) do
    cond do
      Regex.match?(@cpr_response, data) -> :cpr
      Regex.match?(@da_response, data) -> :device_attrs
      Regex.match?(@decrpm_response, data) -> :decrpm
      Regex.match?(@kitty_response, data) -> :kitty_keyboard
      Regex.match?(@osc_color_response, data) -> :osc_color
      Regex.match?(@osc_palette_response, data) -> :osc_palette
      Regex.match?(@xtversion_response, data) -> :xtversion
      Regex.match?(@theme_report_response, data) -> :theme_report
      true -> :other
    end
  end
end
