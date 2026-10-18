Application.put_env(:live_render, LiveRender.OpenUI.TestEndpoint,
  secret_key_base: String.duplicate("openui-test-secret-", 4),
  live_view: [signing_salt: "openui-test-salt"],
  render_errors: [formats: [html: LiveRender.OpenUI.TestEndpoint]],
  server: false
)

Application.put_env(:phoenix, :json_library, Jason)
{:ok, _} = LiveRender.OpenUI.TestEndpoint.start_link()

ExUnit.start()
