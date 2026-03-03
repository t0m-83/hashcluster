defmodule HashClusterWeb.ErrorHTML do
  use HashClusterWeb, :html

  def render("404.html", _assigns), do: "Page non trouvée"
  def render("500.html", _assigns), do: "Erreur interne du serveur"
end
