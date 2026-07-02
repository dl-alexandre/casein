defmodule PreviewCtl.DevIDEPreviewBrowserAdapterTest do
  use DevIDE.TestCase, async: true

  test "DevIDEPreviewBrowser.Adapter exports the PreviewCtl.Adapter callback surface" do
    callbacks = PreviewCtl.Adapter.behaviour_info(:callbacks)

    assert callbacks != []

    for {name, arity} <- callbacks do
      assert function_exported?(DevIDEPreviewBrowser.Adapter, name, arity),
             "expected DevIDEPreviewBrowser.Adapter to export #{name}/#{arity}"
    end
  end

  test "PreviewCtl can dispatch to the adapter when given the module explicitly" do
    assert PreviewCtl.Session.adapter_for(DevIDEPreviewBrowser.Adapter) ==
             DevIDEPreviewBrowser.Adapter
  end
end
