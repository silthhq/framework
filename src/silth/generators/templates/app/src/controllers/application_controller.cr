abstract class ApplicationController < Silth::Controller
  # LAYOUT = "layouts/application"

  # The authenticated user, if any. Install authentication with `silth g auth`.
  def current_user
    ctx.auth_user
  end
end
