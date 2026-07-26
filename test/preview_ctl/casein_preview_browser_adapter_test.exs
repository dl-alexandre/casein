defmodule PreviewCtl.CaseinPreviewBrowserAdapterTest do
  use Casein.TestCase, async: true

  test "CaseinPreviewBrowser.Adapter exports the PreviewCtl.Adapter callback surface" do
    callbacks = PreviewCtl.Adapter.behaviour_info(:callbacks)

    assert callbacks != []

    for {name, arity} <- callbacks do
      assert function_exported?(CaseinPreviewBrowser.Adapter, name, arity),
             "expected CaseinPreviewBrowser.Adapter to export #{name}/#{arity}"
    end
  end

  test "PreviewCtl can dispatch to the adapter when given the module explicitly" do
    assert PreviewCtl.Session.adapter_for(CaseinPreviewBrowser.Adapter) ==
             CaseinPreviewBrowser.Adapter
  end
end
