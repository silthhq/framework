# Routes. List them with `silth routes`.
Silth.routes do
  get "/", HomeController, :index, name: "home"

  # Live component as a full page:
  live "/counter", CounterComponent, name: "counter"

  # JSON API (prefix /api, "api" middleware group: tokens, rate limiting, no CSRF):
  api do
    get "/health" { |ctx| ctx.json({status: "ok", time: Time.utc}) }
  end
end
