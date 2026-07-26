defmodule Casein.Terminals.SessionTemplate.ExportTest do
  use Casein.TestCase, async: true

  alias Casein.Terminals.SessionTemplate.Export

  # Builds a pane map using the TmuxCtl.Topology.pane() field names.
  defp pane(attrs) do
    Map.merge(
      %{
        id: "%0",
        window_id: "@0",
        index: 0,
        active: false,
        left: 0,
        top: 0,
        width: 80,
        height: 24,
        current_command: "bash",
        current_path: nil
      },
      Map.new(attrs)
    )
  end

  defp window(attrs) do
    Map.merge(
      %{
        id: "@0",
        index: 0,
        name: nil,
        active: false,
        pane_list: []
      },
      Map.new(attrs)
    )
  end

  describe "from_topology/2 — guards and top-level shape" do
    test "returns :empty_topology when windows are missing" do
      assert {:error, :empty_topology} = Export.from_topology(%{})
    end

    test "returns :empty_topology when windows is an empty list (string key)" do
      assert {:error, :empty_topology} = Export.from_topology(%{"windows" => []})
    end

    test "builds version-2 template with default name from session" do
      topology = %{
        session: "my session!",
        version: 7,
        windows: [window(%{name: "main", pane_list: [pane(%{id: "%1"})]})]
      }

      {:ok, template} = Export.from_topology(topology)

      assert template["version"] == 2
      # default_name/1 sanitizes non [A-Za-z0-9_-] runs to "_"
      assert template["name"] == "exported_my_session_"
      assert template["metadata"]["source"] == "casein_topology_export"
      assert template["metadata"]["session"] == "my session!"
      assert template["metadata"]["topology_version"] == 7
      # no workspace_root opt -> root is nil and compacted out
      refute Map.has_key?(template, "root")
    end

    test "default name is exported_session when session is nil" do
      topology = %{windows: [window(%{pane_list: [pane(%{id: "%1"})]})]}
      {:ok, template} = Export.from_topology(topology)
      assert template["name"] == "exported_session"
      # metadata had only the source key after compaction
      assert template["metadata"] == %{"source" => "casein_topology_export"}
    end

    test "explicit :name option overrides the derived name" do
      topology = %{session: "s", windows: [window(%{pane_list: [pane(%{id: "%1"})]})]}
      {:ok, template} = Export.from_topology(topology, name: "custom")
      assert template["name"] == "custom"
    end

    test "workspace_root is emitted as ${workspace_root} root expr" do
      topology = %{
        windows: [window(%{pane_list: [pane(%{id: "%1"})]})]
      }

      {:ok, template} = Export.from_topology(topology, workspace_root: "/home/dev/proj")
      assert template["root"] == "${workspace_root}"
    end

    test "reads string-keyed topology fields" do
      topology = %{
        "session" => "str",
        "version" => 3,
        "windows" => [
          %{"name" => "w", "index" => 0, "pane_list" => [pane(%{id: "%1"})]}
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      assert template["metadata"]["topology_version"] == 3
      assert [%{"name" => "w"}] = template["windows"]
    end
  end

  describe "from_topology/2 — windows" do
    test "windows are sorted by index and names/focus derived" do
      topology = %{
        windows: [
          window(%{id: "@2", index: 2, name: "second", pane_list: [pane(%{id: "%2"})]}),
          window(%{
            id: "@1",
            index: 1,
            name: "first",
            active: true,
            pane_list: [pane(%{id: "%1"})]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      assert [first, second] = template["windows"]
      assert first["name"] == "first"
      assert first["focus"] == true
      assert second["name"] == "second"
      # focus false is compacted out (false is not in the reject list, so it stays)
      assert second["focus"] == false
    end

    test "window without a name falls back to window-<index>" do
      topology = %{
        windows: [window(%{id: "@3", index: 3, name: nil, pane_list: [pane(%{id: "%1"})]})]
      }

      {:ok, template} = Export.from_topology(topology)
      assert [%{"name" => "window-3"}] = template["windows"]
    end
  end

  describe "layout — empty and single pane" do
    test "window with no panes yields tiled empty layout" do
      topology = %{windows: [window(%{name: "empty", pane_list: []})]}
      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      assert w["layout"] == %{"direction" => "tiled", "panes" => []}
    end

    test "single pane window exports the pane directly as the layout" do
      topology = %{
        windows: [
          window(%{
            name: "solo",
            pane_list: [
              pane(%{
                id: "%1",
                index: 0,
                active: true,
                current_command: "vim",
                current_path: "/x"
              })
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      layout = w["layout"]

      assert layout["name"] == "vim"
      assert layout["command"] == "vim"
      assert layout["focus"] == true
      # The pane cwd equals the derived window root, so it is dropped from the leaf.
      assert layout["cwd"] == nil
      assert w["root"] == "/x"
      assert layout["metadata"] == %{"source_pane_id" => "%1", "index" => 0}
      # single pane is a leaf, not a split node
      refute Map.has_key?(layout, "direction")
    end
  end

  describe "pane command + name normalization" do
    test "shell commands are dropped from command but named 'shell'" do
      topology = %{
        windows: [
          window(%{
            name: "w",
            pane_list: [
              pane(%{id: "%1", current_command: "zsh", current_path: nil})
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      layout = w["layout"]
      assert layout["name"] == "shell"
      # export_command/1 maps known shells to nil, then compacted away
      refute Map.has_key?(layout, "command")
    end

    test "blank command falls back to pane-<index> name and no command" do
      topology = %{
        windows: [
          window(%{name: "w", pane_list: [pane(%{id: "%1", index: 4, current_command: "   "})]})
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      assert w["layout"]["name"] == "pane-4"
      refute Map.has_key?(w["layout"], "command")
    end

    test "non-shell command keeps full command but names by basename" do
      topology = %{
        windows: [
          window(%{
            name: "w",
            pane_list: [pane(%{id: "%1", current_command: "/usr/bin/htop"})]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      assert w["layout"]["name"] == "htop"
      assert w["layout"]["command"] == "/usr/bin/htop"
    end

    test "duplicate base names are de-duplicated with a suffix" do
      topology = %{
        windows: [
          window(%{
            name: "w",
            pane_list: [
              pane(%{id: "%1", index: 0, left: 0, width: 80, current_command: "vim"}),
              pane(%{id: "%2", index: 1, left: 80, width: 80, current_command: "vim"})
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      panes = w["layout"]["panes"]
      names = Enum.map(panes, & &1["name"])
      assert "vim" in names
      assert "vim-2" in names
    end
  end

  describe "layout — splits" do
    test "side-by-side panes produce a horizontal split with sizes" do
      topology = %{
        windows: [
          window(%{
            name: "split",
            pane_list: [
              pane(%{
                id: "%1",
                index: 0,
                left: 0,
                top: 0,
                width: 80,
                height: 24,
                current_command: "vim"
              }),
              pane(%{
                id: "%2",
                index: 1,
                left: 80,
                top: 0,
                width: 80,
                height: 24,
                current_command: "less"
              })
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      layout = w["layout"]

      assert layout["direction"] == "horizontal"
      assert [left, right] = layout["panes"]
      assert left["name"] == "vim"
      assert left["size"] == 80
      assert right["name"] == "less"
      assert right["size"] == 80
    end

    test "stacked panes produce a vertical split" do
      topology = %{
        windows: [
          window(%{
            name: "vsplit",
            pane_list: [
              pane(%{
                id: "%1",
                index: 0,
                left: 0,
                top: 0,
                width: 80,
                height: 24,
                current_command: "vim"
              }),
              pane(%{
                id: "%2",
                index: 1,
                left: 0,
                top: 24,
                width: 80,
                height: 24,
                current_command: "less"
              })
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      layout = w["layout"]

      assert layout["direction"] == "vertical"
      assert [top, bottom] = layout["panes"]
      assert top["name"] == "vim"
      assert top["size"] == 24
      assert bottom["name"] == "less"
      assert bottom["size"] == 24
    end

    test "nested split: horizontal at top level, vertical within the right child" do
      topology = %{
        windows: [
          window(%{
            name: "nested",
            pane_list: [
              pane(%{
                id: "%1",
                index: 0,
                left: 0,
                top: 0,
                width: 80,
                height: 48,
                current_command: "vim"
              }),
              pane(%{
                id: "%2",
                index: 1,
                left: 80,
                top: 0,
                width: 80,
                height: 24,
                current_command: "top"
              }),
              pane(%{
                id: "%3",
                index: 2,
                left: 80,
                top: 24,
                width: 80,
                height: 24,
                current_command: "less"
              })
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      layout = w["layout"]

      assert layout["direction"] == "horizontal"
      assert [left_child, right_child] = layout["panes"]

      # left child is a single leaf pane (carries a "size" from child_layout)
      assert left_child["name"] == "vim"
      assert left_child["size"] == 80

      # right child is itself a vertical split node, sized by the parent horizontal axis
      assert right_child["direction"] == "vertical"
      assert right_child["size"] == 80
      assert [top, bottom] = right_child["panes"]
      assert top["name"] == "top"
      assert top["size"] == 24
      assert bottom["name"] == "less"
      assert bottom["size"] == 24
    end

    test "non-partitionable geometry falls back to a tiled node" do
      topology = %{
        windows: [
          window(%{
            name: "tiled",
            pane_list: [
              pane(%{
                id: "%1",
                index: 0,
                left: 0,
                top: 0,
                width: 80,
                height: 48,
                current_command: "vim"
              }),
              pane(%{
                id: "%2",
                index: 1,
                left: 80,
                top: 0,
                width: 80,
                height: 24,
                current_command: "top"
              }),
              pane(%{
                id: "%3",
                index: 2,
                left: 40,
                top: 24,
                width: 80,
                height: 24,
                current_command: "less"
              })
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      layout = w["layout"]

      assert layout["direction"] == "tiled"
      assert length(layout["panes"]) == 3
      # tiled children are plain leaves (no "size" key)
      Enum.each(layout["panes"], fn p -> refute Map.has_key?(p, "size") end)
      names = Enum.map(layout["panes"], & &1["name"]) |> Enum.sort()
      assert names == ["less", "top", "vim"]
    end
  end

  describe "cwd / path expressions" do
    test "pane cwd equal to the window root is dropped" do
      topology = %{
        windows: [
          window(%{
            name: "w",
            pane_list: [
              pane(%{
                id: "%1",
                index: 0,
                active: true,
                left: 0,
                width: 80,
                current_command: "vim",
                current_path: "/repo"
              }),
              pane(%{
                id: "%2",
                index: 1,
                left: 80,
                width: 80,
                current_command: "less",
                current_path: "/repo"
              })
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      # window_root is taken from the active pane's current_path
      assert w["root"] == "/repo"
      [left, right] = w["layout"]["panes"]
      # both panes share the window root -> cwd compacted away
      refute Map.has_key?(left, "cwd")
      refute Map.has_key?(right, "cwd")
    end

    test "pane cwd under workspace_root is rewritten relatively" do
      topology = %{
        windows: [
          window(%{
            name: "w",
            pane_list: [
              pane(%{
                id: "%1",
                index: 0,
                active: true,
                left: 0,
                width: 80,
                current_command: "vim",
                current_path: "/ws"
              }),
              pane(%{
                id: "%2",
                index: 1,
                left: 80,
                width: 80,
                current_command: "less",
                current_path: "/ws/sub/dir"
              })
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology, workspace_root: "/ws")
      [w] = template["windows"]
      assert w["root"] == "${workspace_root}"
      [_left, right] = w["layout"]["panes"]
      assert right["cwd"] == "${workspace_root}/sub/dir"
    end

    test "pane cwd outside workspace_root is kept absolute" do
      topology = %{
        windows: [
          window(%{
            name: "w",
            pane_list: [
              pane(%{
                id: "%1",
                index: 0,
                active: true,
                left: 0,
                width: 80,
                current_command: "vim",
                current_path: "/ws"
              }),
              pane(%{
                id: "%2",
                index: 1,
                left: 80,
                width: 80,
                current_command: "less",
                current_path: "/elsewhere/x"
              })
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology, workspace_root: "/ws")
      [_left, right] = hd(template["windows"])["layout"]["panes"]
      assert right["cwd"] == "/elsewhere/x"
    end

    test "window root is nil when no pane has a current_path" do
      topology = %{
        windows: [
          window(%{name: "w", pane_list: [pane(%{id: "%1", current_path: nil})]})
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      [w] = template["windows"]
      refute Map.has_key?(w, "root")
    end
  end

  describe "startup block" do
    test "startup names the active window and active pane" do
      topology = %{
        active_window_id: "@1",
        active_pane_id: "%2",
        windows: [
          window(%{
            id: "@1",
            index: 0,
            name: "main",
            pane_list: [
              pane(%{id: "%1", index: 0, left: 0, width: 80, current_command: "vim"}),
              pane(%{id: "%2", index: 1, left: 80, width: 80, current_command: "htop"})
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      assert template["startup"] == %{"window" => "main", "pane" => "htop"}
    end

    test "startup is omitted entirely when there is no active window or pane" do
      topology = %{
        windows: [window(%{name: "w", pane_list: [pane(%{id: "%1"})]})]
      }

      {:ok, template} = Export.from_topology(topology)
      # startup compacts to %{} which is then dropped from the template
      refute Map.has_key?(template, "startup")
    end

    test "startup keeps only the window when the active pane id is unknown" do
      topology = %{
        active_window_id: "@1",
        active_pane_id: "%missing",
        windows: [
          window(%{
            id: "@1",
            name: "main",
            pane_list: [pane(%{id: "%1", current_command: "vim"})]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology)
      assert template["startup"] == %{"window" => "main"}
    end
  end

  describe "to_yaml/1" do
    test "encodes a simple template with sorted keys and quoted strings" do
      template = %{
        "version" => 2,
        "name" => "demo",
        "focus" => true
      }

      yaml = Export.to_yaml(template)

      assert yaml ==
               """
               focus: true
               name: "demo"
               version: 2
               """
    end

    test "encodes nested maps and lists with indentation" do
      template = %{
        "windows" => [
          %{"name" => "main", "focus" => false}
        ]
      }

      yaml = Export.to_yaml(template)

      assert yaml ==
               """
               windows:
                 - focus: false
                   name: "main"
               """
    end

    test "round-trips a real export through to_yaml without raising" do
      topology = %{
        session: "s",
        version: 1,
        active_window_id: "@1",
        active_pane_id: "%1",
        windows: [
          window(%{
            id: "@1",
            name: "main",
            active: true,
            pane_list: [
              pane(%{
                id: "%1",
                index: 0,
                active: true,
                left: 0,
                width: 80,
                current_command: "vim"
              }),
              pane(%{id: "%2", index: 1, left: 80, width: 80, current_command: "less"})
            ]
          })
        ]
      }

      {:ok, template} = Export.from_topology(topology, workspace_root: "/ws")
      yaml = Export.to_yaml(template)

      assert is_binary(yaml)
      assert String.ends_with?(yaml, "\n")
      assert yaml =~ "version: 2"
      assert yaml =~ ~s(name: "exported_s")
      assert yaml =~ "direction: \"horizontal\""
    end

    test "encodes a list of scalars and null values" do
      template = %{"items" => ["a", 1], "missing" => nil}
      yaml = Export.to_yaml(template)

      assert yaml ==
               """
               items:
                 - "a"
                 - 1
               missing: null
               """
    end
  end
end
