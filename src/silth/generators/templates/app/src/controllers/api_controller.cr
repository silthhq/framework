# Base class for JSON API controllers (routes declared inside `api do … end`).
abstract class ApiController < Silth::Controller
  LAYOUT = false

  def current_user
    ctx.auth_user
  end
end
