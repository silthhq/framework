require "../spec_helper"

describe HomeController do
  it "renders the home page" do
    response = client.get("/")
    response.should be_ok
    response.should contain("__APP_TITLE__")
  end

  it "answers the health check" do
    client.get("/up").json["status"].should eq("ok")
  end
end
